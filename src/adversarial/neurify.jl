"""
    Neurify(max_iter::Int64, tree_search::Symbol)

Neurify combines symbolic reachability analysis with constraint refinement to minimize over-approximation of the reachable set.

# Problem requirement
1. Network: any depth, ReLU activation
2. Input: AbstractPolytope
3. Output: AbstractPolytope

# Return
`CounterExampleResult` or `ReachabilityResult`

# Method
Symbolic reachability analysis and iterative interval refinement (search).
- `max_iter` default `10`.

# Property
Sound but not complete.

# Reference
[S. Wang, K. Pei, J. Whitehouse, J. Yang, and S. Jana,
"Efficient Formal Safety Analysis of Neural Networks,"
*CoRR*, vol. abs/1809.08098, 2018. arXiv: 1809.08098.](https://arxiv.org/pdf/1809.08098.pdf)
[https://github.com/tcwangshiqi-columbia/Neurify](https://github.com/tcwangshiqi-columbia/Neurify)
"""

@with_kw struct Neurify <: Solver
    max_iter::Int64     = 100
    tree_search::Symbol = :DFS
    optimizer = GLPK.Optimizer
end


function solve(solver::Neurify, problem::Problem)
    isbounded(problem.input) || throw(UnboundedInputError("Neurify can only handle bounded input sets."))

    reach = forward_network(solver, problem.network, problem.input)
    result, max_violation_con = check_inclusion(solver, last(reach).sym, problem.output, problem.network)
    result.status == :unknown || return result

    reach_list = [(reach, max_violation_con, Set())]

    # Because of over-approximation, a split may not bisect the input set.
    # Therefore, the gradient remains unchanged (since input didn't change).
    # And this node will be chosen to split forever.
    # To prevent this, we split each node only once if the gradient of this node hasn't change.
    # Each element in splits is a tuple (layer_index, node_index, node_gradient).

    for i in 2:solver.max_iter
        isempty(reach_list) && return CounterExampleResult(:holds)

        reach, max_violation_con, splits = select!(reach_list, solver.tree_search)

        subdomains = constraint_refinement(solver, problem.network, reach, max_violation_con, splits)

        for domain in subdomains
            reach = forward_network(solver, problem.network, domain)
            result, max_violation_con = check_inclusion(solver, last(reach).sym, problem.output, problem.network)
            if result.status == :violated
                return result
            elseif result.status == :unknown
                push!(reach_list, (reach, max_violation_con, copy(splits)))
            end
        end
    end
    return CounterExampleResult(:unknown)
end

function check_inclusion(solver::Neurify, reach::SymbolicInterval,
                         output::AbstractPolytope, nnet::Network)
    # The output constraint is in the form A*x < b
    # We try to maximize output constraint to find a violated case, or to verify the inclusion.
    # Suppose the output is [1, 0, -1] * x < 2, Then we are maximizing reach.Up[1] * 1 + reach.Low[3] * (-1)

    input_domain = domain(reach)

    model = Model(solver); set_silent(model)
    x = @variable(model, [1:dim(input_domain)])
    add_set_constraint!(model, input_domain, x)

    max_violation = 0.0
    max_violation_con = nothing
    for (i, cons) in enumerate(constraints_list(output))
        # NOTE can be taken out of the loop, but maybe there's no advantage
        # NOTE max.(M, 0) * U  + ... is a common operation, and maybe should get a name. It's also an "interval map".
        a, b = cons.a, cons.b
        obj = max.(a, 0)'*reach.Up + min.(a, 0)'*reach.Low

        @objective(model, Max, obj * [x; 1] - b)
        optimize!(model)

        if termination_status(model) == OPTIMAL
            if compute_output(nnet, value(x)) ∉ output
                return CounterExampleResult(:violated, value(x)), nothing
            end

            viol = objective_value(model)
            if viol > max_violation
                max_violation = viol
                max_violation_con = a
            end

        # NOTE This entire else branch should be eliminated for the paper version
        else
            # NOTE Is this even valid if the problem isn't solved optimally?
            if value(x) ∈ input_domain
                error("Not OPTIMAL, but x in the input set.\n
                This is usually caused by open input set.\n
                Please check your input constraints.")
            end
            # TODO can we be more descriptive?
            error("No solution, please check the problem definition.")
        end

    end

    if max_violation > 0.0
        return CounterExampleResult(:unknown), max_violation_con
    else
        return CounterExampleResult(:holds), nothing
    end
end

function constraint_refinement(solver::Neurify,
                               nnet::Network,
                               reach::Vector{<:SymbolicIntervalGradient},
                               max_violation_con::AbstractVector{Float64},
                               splits)

    i, j, influence = get_max_nodewise_influence(solver, nnet, reach, max_violation_con, splits)
    # We can generate three more constraints
    # Symbolic representation of node i j is Low[i][j,:] and Up[i][j,:]
    aL, bL = reach[i].sym.Low[j, 1:end-1], reach[i].sym.Low[j, end]
    aU, bU = reach[i].sym.Up[j, 1:end-1], reach[i].sym.Up[j, end]

    # custom intersection function that doesn't do constraint pruning
    ∩ = (set, lc) -> HPolytope([constraints_list(set); lc])

    subsets = [domain(reach[1])] # all the reaches have the same domain, so we can pick [1]

    # If either of the normal vectors is the 0-vector, we must skip it.
    # It cannot be used to create a halfspace constraint.
    # NOTE: how can this come about, and does it mean anything?
    if !iszero(aL)
        subsets = subsets .∩ [HalfSpace(aL, -bL), HalfSpace(aL, -bL), HalfSpace(-aL, bL)]
    end
    if !iszero(aU)
        subsets = subsets .∩ [HalfSpace(aU, -bU), HalfSpace(-aU, bU), HalfSpace(-aU, bU)]
    end
    return filter(!isempty, subsets)
end


function get_max_nodewise_influence(solver::Neurify,
                                    nnet::Network,
                                    reach::Vector{<:SymbolicIntervalGradient},
                                    max_violation_con::AbstractVector{Float64},
                                    splits)

    LΛ, UΛ = reach[end].LΛ, reach[end].UΛ
    is_ambiguous_activation(i, j) = (0 < LΛ[i][j] < 1) || (0 < UΛ[i][j] < 1)

    # We want to find the node with the largest influence
    # Influence is defined as gradient * interval width
    # The gradient is with respect to a loss defined by the most violated constraint.
    LG = UG = max_violation_con
    i_max, j_max, influence_max = 0, 0, -Inf

    # Backpropagation to calculate the node-wise gradient
    for i in reverse(1:length(nnet.layers))
        layer = nnet.layers[i]
        sym = reach[i].sym
        if layer.activation isa ReLU
            for j in 1:n_nodes(layer)
                if is_ambiguous_activation(i, j)
                    # taking `influence = max_gradient * reach.r[i][j]*k` would be
                    # different from original paper, but can improve the split efficiency.
                    # where `k = n-i+1`, i.e. counts up from 1 as you go back in layers.

                    # radius wrt to the jth node/hidden dimension
                    r = radius(sym, j)
                    influence = max(abs(LG[j]), abs(UG[j])) * r
                    if influence >= influence_max && (i, j, influence) ∉ splits
                        i_max, j_max, influence_max = i, j, influence
                    end
                end
            end
        end

        LG_hat = max.(LG, 0.0) .* LΛ[i] .+ min.(LG, 0.0) .* UΛ[i]
        UG_hat = min.(UG, 0.0) .* LΛ[i] .+ max.(UG, 0.0) .* UΛ[i]

        LG, UG = interval_map(layer.weights', LG_hat, UG_hat)
    end

    # NOTE can omit this line in the paper version
    (i_max == 0 || j_max == 0) && error("Can not find valid node to split")

    push!(splits, (i_max, j_max, influence_max))

    return (i_max, j_max, influence_max)
end



function forward_network(solver::Neurify, network::Network, input)
    forward_network(solver, network, init_symbolic_grad(input))
end
function forward_network(solver::Neurify, network::Network, input::SymbolicIntervalGradient)
    reachable = [input = forward_layer(solver, L, input) for L in network.layers]
    return reachable
end


function forward_layer(solver::Neurify, layer::Layer, input)
    return forward_act(solver, forward_linear(solver, input, layer), layer)
end

# Symbolic forward_linear
function forward_linear(solver::Neurify, input::SymbolicIntervalGradient, layer::Layer)
    output_Low, output_Up = interval_map(layer.weights, input.sym.Low, input.sym.Up)
    output_Up[:, end] += layer.bias
    output_Low[:, end] += layer.bias
    sym = SymbolicInterval(output_Low, output_Up, domain(input))
    return SymbolicIntervalGradient(sym, input.LΛ, input.UΛ)
end

# Symbolic forward_act
function forward_act(solver::Neurify, input::SymbolicIntervalGradient, layer::Layer{ReLU})

    n_node = n_nodes(layer)

    output_Low, output_Up = copy(input.sym.Low), copy(input.sym.Up)
    LΛᵢ, UΛᵢ = zeros(n_node), ones(n_node)

    # Symbolic linear relaxation
    # This is different from ReluVal
    for j in 1:n_node
        # Loop-local variable bindings for notational convenience.
        # These are direct views into the rows of the parent arrays.
        out_lowᵢⱼ, out_upᵢⱼ = @views output_Low[j, :], output_Up[j, :]

        up_low, up_up = bounds(upper(input), j)
        low_low, low_up = bounds(lower(input), j)

        up_slope = relaxed_relu_gradient(up_low, up_up)
        low_slope = relaxed_relu_gradient(low_low, low_up)

        out_upᵢⱼ .*= up_slope
        out_upᵢⱼ[end] += up_slope * max(-up_low, 0)

        out_lowᵢⱼ .*= low_slope

        LΛᵢ[j], UΛᵢ[j] = low_slope, up_slope
    end
    sym = SymbolicInterval(output_Low, output_Up, domain(input))
    LΛ = push!(input.LΛ, LΛᵢ)
    UΛ = push!(input.UΛ, UΛᵢ)
    return SymbolicIntervalGradient(sym, LΛ, UΛ)
end

function forward_act(solver::Neurify, input::SymbolicIntervalGradient, layer::Layer{Id})
    n_node = n_nodes(layer)
    LΛ = push!(input.LΛ, ones(n_node))
    UΛ = push!(input.UΛ, ones(n_node))
    return SymbolicIntervalGradient(input.sym, LΛ, UΛ)
end
