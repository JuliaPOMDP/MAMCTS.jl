## We can use the following directly without modification
## 1. domain_knowledge.jl for Rollout, init_Q and init_N functions
## 2. FVMCTSSolver for representing the overall MCTS (underlying things will change)
using StaticArrays
using Parameters
using Base.Threads: @spawn

abstract type AbstractCoordinationStrategy end

struct VarEl <: AbstractCoordinationStrategy
end

@with_kw struct MaxPlus <:AbstractCoordinationStrategy
    message_iters::Int64 = 10
    message_norm::Bool = true
    use_agent_utils::Bool = false
    node_exploration::Bool = true
    edge_exploration::Bool = true
end

@with_kw mutable struct FVMCTSSolver <: AbstractMCTSSolver
    n_iterations::Int64 = 100
    max_time::Float64 = Inf
    depth::Int64 = 10
    exploration_constant::Float64 = 1.0
    rng::AbstractRNG = Random.GLOBAL_RNG
    estimate_value::Any = RolloutEstimator(RandomSolver(rng))
    init_Q::Any = 0.0
    init_N::Any = 0
    reuse_tree::Bool = false
    coordination_strategy::Any = VarEl()
end


# JointMCTS tree has to be different, to efficiently encode Q-stats
mutable struct JointMCTSTree{S,A,CS<:CoordinationStatistics}

    # To track if state node in tree already
    # NOTE: We don't strictly need this at all if no tree reuse...
    state_map::Dict{AbstractVector{S},Int64}

    # these vectors have one entry for each state node
    # Only doing factored satistics (for actions), not state components
    # Looks like we don't need child_ids
    total_n::Vector{Int}
    s_labels::Vector{AbstractVector{S}}

    # Track stats for all action components over the n_iterations
    all_agent_actions::Vector{AbstractVector{A}}

    coordination_stats::CS
    lock::ReentrantLock
    # Don't need a_labels because need to do var-el for best action anyway
end

# Just a glorified wrapper now
function JointMCTSTree(all_agent_actions::Vector{AbstractVector{A}},
                       coordination_stats::CS,
                       init_state::AbstractVector{S},
                       lock::ReentrantLock,
                       sz::Int64=10000) where {S, A, CS <: CoordinationStatistics}

    return JointMCTSTree{S,A,CS}(Dict{typeof(init_state),Int64}(),
                                 sizehint!(Int[], sz),
                                 sizehint!(typeof(init_state)[], sz),
                                 all_agent_actions,
                                 coordination_stats,
                                 lock
                                 )
end # function



Base.isempty(t::JointMCTSTree) = isempty(t.state_map)
state_nodes(t::JointMCTSTree) = (JointStateNode(t, id) for id in 1:length(t.total_n))

struct JointStateNode{S}
    tree::JointMCTSTree{S}
    id::Int64
end

#get_state_node(tree::JointMCTSTree, id) = JointStateNode(tree, id)

# accessors for state nodes
@inline state(n::JointStateNode) = n.tree.s_labels[n.id]
@inline total_n(n::JointStateNode) = n.tree.total_n[n.id]

## No need for `children` or ActionNode just yet

mutable struct JointMCTSPlanner{S, A, SE, CS <: CoordinationStatistics, RNG <: AbstractRNG} <: AbstractMCTSPlanner{JointMDP{S,A}}
    solver::FVMCTSSolver
    mdp::JointMDP{S,A}
    tree::JointMCTSTree{S,A,CS}
    solved_estimate::SE
    rng::RNG
end

function varel_joint_mcts_planner(solver::FVMCTSSolver,
                                  mdp::JointMDP{S,A},
                                  init_state::AbstractVector{S},
                                  ) where {S,A}

    # Get coord graph comps from maximal cliques of graph
    adjmat = coord_graph_adj_mat(mdp)
    @assert size(adjmat)[1] == n_agents(mdp) "Adjacency Mat does not match number of agents!"

    adjmatgraph = SimpleGraph(adjmat)
    coord_graph_components = maximal_cliques(adjmatgraph)
    min_degree_ordering = sortperm(degree(adjmatgraph))

    # Initialize full agent actions
    # TODO(jkg): this is incorrect? Or we need to override actiontype to refer to agent actions?
    all_agent_actions = Vector{actiontype(mdp)}(undef, n_agents(mdp))
    for i = 1:n_agents(mdp)
        all_agent_actions[i] = get_agent_actions(mdp, i)
    end

    ve_stats = VarElStatistics{eltype(init_state)}(coord_graph_components, min_degree_ordering,
                                                   Dict{typeof(init_state),Vector{Vector{Int64}}}(),
                                                   Dict{typeof(init_state),Vector{Vector{Int64}}}(),
                                                   )

    # Create tree FROM CURRENT STATE
    tree = JointMCTSTree(all_agent_actions, ve_stats,
                         init_state, ReentrantLock(), solver.n_iterations)
    se = convert_estimator(solver.estimate_value, solver, mdp)

    return JointMCTSPlanner(solver, mdp, tree, se, solver.rng)
end # end JointMCTSPlanner


function maxplus_joint_mcts_planner(solver::FVMCTSSolver,
                                    mdp::JointMDP{S,A},
                                    init_state::AbstractVector{S},
                                    message_iters::Int64,
                                    message_norm::Bool,
                                    use_agent_utils::Bool,
                                    node_exploration::Bool,
                                    edge_exploration::Bool,
                                    ) where {S,A}

    @assert (node_exploration || edge_exploration) "At least one of nodes or edges should explore!"

    adjmat = coord_graph_adj_mat(mdp)
    @assert size(adjmat)[1] == n_agents(mdp) "Adjacency Mat does not match number of agents!"

    adjmatgraph = SimpleGraph(adjmat)
    # Initialize full agent actions
    # TODO(jkg): this is incorrect? Or we need to override actiontype to refer to agent actions?
    all_agent_actions = Vector{actiontype(mdp)}(undef, n_agents(mdp))
    for i = 1:n_agents(mdp)
        all_agent_actions[i] = get_agent_actions(mdp, i)
    end

    mp_stats = MaxPlusStatistics{eltype(init_state)}(adjmatgraph,
                                                     message_iters,
                                                     message_norm,
                                                     use_agent_utils,
                                                     node_exploration,
                                                     edge_exploration,
                                                     Dict{typeof(init_state),PerStateMPStats}())

    # Create tree FROM CURRENT STATE
    tree = JointMCTSTree(all_agent_actions, mp_stats,
                         init_state, ReentrantLock(), solver.n_iterations)
    se = convert_estimator(solver.estimate_value, solver, mdp)

    return JointMCTSPlanner(solver, mdp, tree, se, solver.rng)
end


# Reset tree.
function clear_tree!(planner::JointMCTSPlanner)

    # Clear out state hash dict entirely
    empty!(planner.tree.state_map)

    # Empty state vectors with state hints
    sz = min(planner.solver.n_iterations, 100_000)

    empty!(planner.tree.s_labels)
    sizehint!(planner.tree.s_labels, planner.solver.n_iterations)

    # Don't touch all_agent_actions and coord graph component
    # Just clear comp stats dict
    clear_statistics!(planner.tree.coordination_stats)
end

# function get_state_node(tree::JointMCTSTree, s, planner::JointMCTSPlanner)
#     if haskey(tree.state_map, s)
#         return JointStateNode(tree, tree.state_map[s]) # Is this correct? Not equiv to vanilla
#     else
#         return insert_node!(tree, planner, s)
#     end
# end

MCTS.init_Q(n::Number, mdp::JointMDP, s, c, a) = convert(Float64, n)
MCTS.init_N(n::Number, mdp::JointMDP, s, c, a) = convert(Int, n)


# no computation is done in solve - the solver is just given the mdp model that it will work with
function POMDPs.solve(solver::FVMCTSSolver, mdp::JointMDP)
    if typeof(solver.coordination_strategy) == VarEl
        return varel_joint_mcts_planner(solver, mdp, initialstate(mdp, solver.rng))
    elseif typeof(solver.coordination_strategy) == MaxPlus
        return maxplus_joint_mcts_planner(solver, mdp, initialstate(mdp, solver.rng), solver.coordination_strategy.message_iters,
                                          solver.coordination_strategy.message_norm, solver.coordination_strategy.use_agent_utils,
                                          solver.coordination_strategy.node_exploration, solver.coordination_strategy.edge_exploration)
    else
        throw(error("Not Implemented"))
    end
end


# IMP: Overriding action for JointMCTSPlanner here
# NOTE: Hardcoding no tree reuse for now
function POMDPs.action(planner::JointMCTSPlanner, s)
    clear_tree!(planner) # Always call this at the top
    plan!(planner, s)
    action =  coordinate_action(planner.mdp, planner.tree, s)
    return action
end

function POMDPModelTools.action_info(planner::JointMCTSPlanner, s)
    clear_tree!(planner) # Always call this at the top
    plan!(planner, s)
    action = coordinate_action(planner.mdp, planner.tree, s)
    return action, nothing
end

## Not implementing value functions right now....
## ..Is it just the MAX of the best action, rather than argmax???

# Could reuse plan! from vanilla.jl. But I don't like
# calling an element of an abstract type like AbstractMCTSPlanner
function plan!(planner::JointMCTSPlanner, s)
    planner.tree = build_tree(planner, s)
end

# Build_Tree can be called on the assumption that no reuse AND tree is reinitialized
function build_tree(planner::JointMCTSPlanner, s::AbstractVector{S}) where S

    n_iterations = planner.solver.n_iterations
    depth = planner.solver.depth

    root = insert_node!(planner.tree, planner, s)
    # build the tree
    @sync for n = 1:n_iterations
        @spawn simulate(planner, root, depth)
    end
    return planner.tree
end

function simulate(planner::JointMCTSPlanner, node::JointStateNode, depth::Int64)

    mdp = planner.mdp
    rng = planner.rng
    s = state(node)
    tree = node.tree


    # once depth is zero return
    if isterminal(planner.mdp, s)
        return 0.0
    elseif depth == 0
        return estimate_value(planner.solved_estimate, planner.mdp, s, depth)
    end

    # Choose best UCB action (NOT an action node)
    ucb_action = coordinate_action(mdp, planner.tree, s, planner.solver.exploration_constant, node.id)

    # @show ucb_action
    # MC Transition
    sp, r = gen(DDNOut(:sp, :r), mdp, s, ucb_action, rng)

    spid = lock(tree.lock) do
        get(tree.state_map, sp, 0) # may be non-zero even with no tree reuse
    end
    if spid == 0
        spn = insert_node!(tree, planner, sp)
        spid = spn.id
        # TODO define estimate_value
        q = r .+ discount(mdp) * estimate_value(planner.solved_estimate, planner.mdp, sp, depth - 1)
    else
        q = r .+ discount(mdp) * simulate(planner, JointStateNode(tree, spid) , depth - 1)
    end

    ## Not bothering with tree vis right now
    # Augment N(s)
    lock(tree.lock) do
        tree.total_n[node.id] += 1
    end

    # Update component statistics! (non-trivial)
    # This is related but distinct from initialization
    update_statistics!(mdp, tree, s, ucb_action, q)

    return q
end

POMDPLinter.@POMDP_require simulate(planner::JointMCTSPlanner, s, depth::Int64) begin
    mdp = planner.mdp
    P = typeof(mdp)
    @assert P <: JointMDP       # req does different thing?
    SV = statetype(P)
    @assert typeof(SV) <: AbstractVector # TODO: Is this correct?
    AV = actiontype(P)
    @assert typeof(A) <: AbstractVector
    @req discount(::P)
    @req isterminal(::P, ::SV)
    @subreq insert_node!(planner.tree, planner, s)
    @subreq estimate_value(planner.solved_estimate, mdp, s, depth)
    @req gen(::DDNOut{(:sp, :r)}, ::P, ::SV, ::A, ::typeof(planner.rng))

    # MMDP reqs
    @req get_agent_actions(::P, ::Int64)
    @req get_agent_actions(::P, ::Int64, ::eltype(SV))
    @req n_agents(::P)
    @req coord_graph_adj_mat(::P)

    # TODO: Should we also have this requirement for SV?
    @req isequal(::S, ::S)
    @req hash(::S)
end



function insert_node!(tree::JointMCTSTree{S,A,CS}, planner::JointMCTSPlanner,
                      s::AbstractVector{S}) where {S,A,CS <: CoordinationStatistics}

    lock(tree.lock) do
        push!(tree.s_labels, s)
        tree.state_map[s] = length(tree.s_labels)
        push!(tree.total_n, 1)

        # TODO: Could actually make actions state-dependent if need be
        init_statistics!(tree, planner, s)
    end
    # length(tree.s_labels) is just an alias for the number of state nodes
    ls = lock(tree.lock) do
        length(tree.s_labels)
    end
    return JointStateNode(tree, ls)
end

POMDPLinter.@POMDP_require insert_node!(tree::JointMCTSTree, planner::JointMCTSPlanner, s) begin

    P = typeof(planner.mdp)
    AV = actiontype(P)
    A = eltype(AV)
    SV = typeof(s)
    S = eltype(SV)

    # TODO: Review IQ and IN
    IQ = typeof(planner.solver.init_Q)
    if !(IQ <: Number) && !(IQ <: Function)
        @req init_Q(::IQ, ::P, ::S, ::Vector{Int64}, ::AbstractVector{A})
    end

    IN = typeof(planner.solver.init_N)
    if !(IN <: Number) && !(IN <: Function)
        @req init_N(::IQ, ::P, ::S, ::Vector{Int64}, ::AbstractVector{A})
    end

    @req isequal(::S, ::S)
    @req hash(::S)
end
