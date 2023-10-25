export extremevaltheory_dims_persistences, extremevaltheory_dims, extremevaltheory_dim
export extremevaltheory_local_dim_persistence
export extremal_index_sueveges
export estimate_gpd_parameters
export extremevaltheory_gpdfit_pvalues
export BlockMaxima
export Exceedances
using Distances: euclidean
using Statistics: mean, quantile, var
import ProgressMeter
include("gpd.jl")
include("gev.jl")


struct BlockMaxima
    blocksize::Int
    p::Real
end

struct Exceedances
    p::Real
    estimator::Symbol
end


"""
    extremevaltheory_dim(X::StateSpaceSet, p::Real; kwargs...) → Δ

Convenience syntax that returns the mean of the local dimensions of
[`extremevaltheory_dims_persistences`](@ref), which approximates
a fractal dimension of `X` using extreme value theory and quantile probability `p`.

See also [`extremevaltheory_gpdfit_pvalues`](@ref) for obtaining confidence on the results.
"""
function extremevaltheory_dim(X, p; kw...)
    Δloc, θloc = extremevaltheory_dims_persistences(X, p; compute_persistence = false, kw...)
    return mean(Δloc)
end

"""
    extremevaltheory_dims(X::StateSpaceSet, p::Real; kwargs...) → Δloc

Convenience syntax that returns the local dimensions of
[`extremevaltheory_dims_persistences`](@ref).
"""
function extremevaltheory_dims(X, p; kw...)
    Δloc, θloc = extremevaltheory_dims_persistences(X, p; compute_persistence = false, kw...)
    return Δloc
end

"""
    extremevaltheory_dims_persistences(x::AbstractStateSpaceSet, p::Real; kwargs...)

Return the local dimensions `Δloc` and the persistences `θloc` for each point in the
given set for quantile probability `p`, according to the estimation done via extreme value
theory [Lucarini2016](@cite).
The computation is parallelized to available threads (`Threads.nthreads()`).

See also [`extremevaltheory_gpdfit_pvalues`](@ref) for obtaining confidence on the results.

## Keyword arguments

- `show_progress = true`: displays a progress bar.
- `estimator = :mm`: how to estimate the `σ` parameter of the
  Generalized Pareto Distribution. The local fractal dimension is `1/σ`.
  The possible values are: `:exp, :mm`, as in [`estimate_gpd_parameters`](@ref).
- `compute_persistence = true:` whether to aso compute local persistences
  `θloc` (also called extremal index). If `false`, `θloc` are `NaN`s.
- `allocate_matrix = false`: If `true`, the code calls a method that
  attempts to allocate an `N×N` matrix (`N = length(X)`) that stores the
  pairwise Euclidean distances. This method is faster due to optimizations of
  `Distances.pairwise` but will error if the computer does not have enough available
  memory for the matrix allocation.

## Description

For each state space point ``\\mathbf{x}_i`` in `X` we compute
``g_i = -\\log(||\\mathbf{x}_i - \\mathbf{x}_j|| ) \\; \\forall j = 1, \\ldots, N`` with
``||\\cdot||`` the Euclidean distance. Next, we choose an extreme quantile probability
``p`` (e.g., 0.99) for the distribution of ``g_i``. We compute ``g_p`` as the ``p``-th
quantile of ``g_i``. Then, we collect the exceedances of ``g_i``, defined as
``E_i = \\{ g_i - g_p: g_i \\ge g_p \\}``, i.e., all values of ``g_i`` larger or equal to
``g_p``, also shifted by ``g_p``. There are in total ``n = N(1-q)`` values in ``E_i``.
According to extreme value theory, in the limit ``N \\to \\infty`` the values ``E_i``
follow a two-parameter Generalized Pareto Distribution (GPD) with parameters
``\\sigma,\\xi`` (the third parameter ``\\mu`` of the GPD is zero due to the
positive-definite construction of ``E``). Within this extreme value theory approach,
the local dimension ``\\Delta^{(E)}_i`` assigned to state space point ``\\textbf{x}_i``
is given by the inverse of the ``\\sigma`` parameter of the
GPD fit to the data[^Lucarini2012], ``\\Delta^{(E)}_i = 1/\\sigma``.
``\\sigma`` is estimated according to the `estimator` keyword.

A more precise description of this process is given in the review paper [Datseris2023](@cite).
"""

function extremevaltheory_dims_persistences(X::AbstractStateSpaceSet, type;
    show_progress = envprog(), kw...
)
    # The algorithm in the end of the day loops over points in `X`
    # and applies the local algorithm.
    # However, we write two different loop functions; one can
    # compute the distance matrix directly from the get go.
    # However, this is likely to not fit in memory even for a moderately high
    # amount of points in `X`. So, we make an alternative that goes row by row.
    N = length(X)
    Δloc = zeros(eltype(X), N)
    θloc = copy(Δloc)
    p = type.p
    progress = ProgressMeter.Progress(
        N; desc = "Extreme value theory dim: ", enabled = show_progress
    )
    logdists = [copy(Δloc) for _ in 1:Threads.nthreads()]
    Threads.@threads for j in eachindex(X)
        logdist = logdists[Threads.threadid()]
        @inbounds map!(x -> -log(euclidean(x, X[j])), logdist, vec(X))
        D, θ = extremevaltheory_local_dim_persistence(logdist, p; kw...)
        Δloc[j] = D
        θloc[j] = θ
        ProgressMeter.next!(progress)
    end
    return Δloc, θloc
end



function extremevaltheory_dims_persistences(X::AbstractStateSpaceSet, p::Real;
    estimator = :exp, kw...
)
type = Exceedances(p, estimator)
extremevaltheory_dims_persistences(X, type; kw...)
end



function extremevaltheory_local_dim_persistence(
        logdist::AbstractVector{<:Real}, p::Real; compute_persistence = true, estimator = :mm
    )
    σ, ξ, E, thresh = extremevaltheory_local_gpd_fit(logdist, p, estimator)
    # The local dimension is the reciprocal σ
    Δ = 1/σ
    # Lastly, obtain θ if asked for
    if compute_persistence
        θ = extremal_index_sueveges(logdist, p, thresh)
    else
        θ = NaN
    end
    return Δ, θ
end

function extremevaltheory_local_gpd_fit(logdist, p, estimator)
    # Here `logdist` is already the -log(euclidean) distance of one point
    # to all other points in the set.
    # Extract the threshold corresponding to the quantile defined
    thresh = quantile(logdist, p)
    # Filter to obtain Peaks Over Threshold (PoTs)
    # PoTs = logdist[findall(≥(thresh), logdist)]
    PoTs = filter(≥(thresh), logdist)
    # We need to filter, because one entry will have infinite value,
    # because one entry has 0 Euclidean distance in the set.
    filter!(isfinite, PoTs)
    # We re-use to PoTs vector do define the exceedances (save memory allocations)
    exceedances = (PoTs .-= thresh)
    # We need to ensure that the minimum of the exceedences is zero,
    # and sometimes it can be very close, but not exactly, zero
    minE = minimum(exceedances)
    if minE > 0
        exceedances .-= minE
    end
    # Extract the GPD parameters.
    σ, ξ = estimate_gpd_parameters(exceedances, estimator)
    return σ, ξ, exceedances, thresh
end

"""
    extremal_index_sueveges(y::AbstractVector, p)

Compute the extremal index θ of `y` through the Süveges formula for quantile probability `p`,
using the algorithm of [Sveges2007](@cite).
"""
function extremal_index_sueveges(y::AbstractVector, p::Real,
        # These arguments are given for performance optim; not part of public API
        thresh::Real = quantile(y, p)
    )
    p = 1 - p
    Li = findall(x -> x > thresh, y)
    Ti = diff(Li)
    Si = Ti .- 1
    Nc = length(findall(x->x>0, Si))
    N = length(Ti)
    θ = (sum(p.*Si)+N+Nc - sqrt( (sum(p.*Si) +N+Nc).^2 - 8*Nc*sum(p.*Si)) )./(2*sum(p.*Si))
    return θ
end

# convenience function
"""
    extremevaltheory_local_dim_persistence(X::StateSpaceSet, ζ, p::Real; kw...)

Return the local values `Δ, θ` of the fractal dimension and persistence of `X` around a
state space point `ζ`. `p` and `kw` are as in [`extremevaltheory_dims_persistences`](@ref).
"""
function extremevaltheory_local_dim_persistence(
        X::AbstractStateSpaceSet, ζ::AbstractVector, p::Real; kw...
    )
    logdist = map(x -> -log(euclidean(x, ζ)), X)
    Δ, θ = extremevaltheory_local_dim_persistence(logdist, p; kw...)
    return Δ, θ
end


function extremevaltheory_local_dim_persistence(
        logdist::AbstractVector{<:Real}, type::Exceedances; compute_persistence = true, estimator = :mm
    )
    p = type.p
    estimator = type.estimator

    σ, ξ, E, thresh = extremevaltheory_local_gpd_fit(logdist, p, estimator)
    # The local dimension is the reciprocal σ
    Δ = 1/σ
    # Lastly, obtain θ if asked for
    if compute_persistence
        θ = extremal_index_sueveges(logdist, p, thresh)
    else
        θ = NaN
    end
    return Δ, θ
end


"""
    extremevaltheory_local_dim_persistence(
        logdist::AbstractVector{<:Real}, type::Blockmaxima; compute_persistence = true, estimator = :mm
    )

This function computes the local dimensions Δ and the extremal index θ for each observation in the 
trajectory x. It uses the block maxima approach: divides the data in N/blocksize blocks of length blocksize, 
where N is the number of data, and takes the maximum of those bloks as samples of the maxima of the process.
In order for this method to work correctly, both the blocksize and the number of blocks must be high.
Note that there are data points that are not used by the algorithm. Since it is not always possible to 
express the number of input data poins as N = blocksize * nblocks + 1. To reduce the number of unused
data, chose an N equal or superior to blocksize * nblocks + 1. 
The extremal index can be interpreted as the inverse of the persistance of the extremes around
that point.
"""
function extremevaltheory_local_dim_persistence(
        logdist::AbstractVector{<:Real}, type::BlockMaxima; compute_persistence = true, estimator = :mm
    )
    p = type.p
    N = length(logdist)
    blocksize = type.blocksize
    nblocks = floor(Int, N/blocksize)
    newN = blocksize*nblocks + 1
    firstindex = N - newN + 1
    Δ = zeros(newN)
    θ = zeros(newN)
    progress = ProgressMeter.Progress(
        N - firstindex; desc = "Extreme value theory dim: ", enabled = true
    )
    for (j, k) in enumerate(range(firstindex,N))
        duplicatepoint = !isempty(findall(x -> x == Inf, logdista))
        if duplicatepoint
            error("Duplicated data point on the input")
        end
        if compute_persistence
            θ[j] = extremal_index_sueveges(logdista, p)
        else
            θ = NaN
        end
        # Extract the maximum of each block
        maxvector = maximum(reshape(logdista,(blocksize,nblocks)),dims= 1)
        σ = estimate_gev_scale(maxvector)
        Δ[j] = 1 / σ
        next!(progress)
    end
    return Δ, θ
end