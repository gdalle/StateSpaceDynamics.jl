export SwitchingLinearDynamicalSystem, fit!, initialize_slds, variational_expectation!
"""
Switching Linear Dynamical System

Struct to Encode a Hidden Markov model that switches among K distinct LinearDyanmicalSystems

# Fields 
- `A::V`: Transition matrix for mode switching. 
- `B::VL`: Vector of Linear Dynamical System models. 
- `πₖ::V`: Initial state distribution.
- `K::Int`: Number of modes. 
"""
mutable struct SwitchingLinearDynamicalSystem{T<:Real,M<:AbstractMatrix{T}, V<:AbstractVector{T}, VL<:AbstractVector{<:LinearDynamicalSystem}} <: AbstractHMM
    A::M 
    B::VL 
    πₖ::V  
    K::Int 
end


"""
    Random.rand(rng, slds, T)

Generate synthetic data with switching LDS models

#Arguments 
- `rng:AbstractRNG`: Random number generator
- `slds::SwitchingLinearDynamicalSystem`: The switching LDS model 
- `T::Int`: Number of time steps to sample

# Returns
- `Tuple{Array,Array, Array}`: Latent states (x), observations (y), and mode sequences (z). 
"""
function Random.rand(rng::AbstractRNG, slds::SwitchingLinearDynamicalSystem, T::Int)
    state_dim = slds.B[1].latent_dim
    obs_dim = slds.B[1].obs_dim
    K = slds.K

    x = zeros(state_dim, T)  # Latent states
    y = zeros(obs_dim, T)    # Observations
    z = zeros(Int, T)        # Mode sequence

    # Sample initial mode
    z[1] = rand(rng, Categorical(slds.πₖ / sum(slds.πₖ)))
    x[:, 1] = rand(rng, MvNormal(zeros(state_dim), slds.B[z[1]].state_model.Q))
    y[:, 1] = rand(rng, MvNormal(slds.B[z[1]].obs_model.C * x[:, 1], slds.B[z[1]].obs_model.R))

    @views for t in 2:T
        # Sample mode based on transition probabilities
        z[t] = rand(Categorical(slds.A[z[t-1], :] ./ sum(slds.A[z[t-1], :])))
        # Update latent state and observation
        x[:, t] = rand(
          MvNormal(slds.B[z[t]].state_model.A * x[:, t-1], slds.B[z[t]].state_model.Q)
        )
        y[:, t] = rand(
          MvNormal(slds.B[z[t]].obs_model.C * x[:, t], slds.B[z[t]].obs_model.R)
        )
    end

    return x, y, z
end

function Random.rand(slds::SwitchingLinearDynamicalSystem, T::Int)
    return rand(Random.default_rng(), slds, T)
end

"""
    initialize_slds(;K::Int=2, d::Int=2, p::Int=10, self_bias::Float64=5.0, seed::Int=42)

Initialize a Switching Linear Dynamical System with random parameters.
"""
function initialize_slds(;K::Int=2, d::Int=2, p::Int=10, self_bias::Float64=5.0, seed::Int=42)
    Random.seed!(seed)
    
    # Transition matrix using Dirichlet with self-bias
    A = zeros(K, K)
    for i in 1:K
        # Create concentration parameters with higher value for self-transition
        alpha = ones(K)
        alpha[i] = self_bias  # Bias toward self-transition
        
        # Sample from Dirichlet distribution
        A[i, :] = rand(Dirichlet(alpha))
    end
    
    # Initial state probabilities
    πₖ = rand(Dirichlet(ones(K)))
    
    # State parameters
    Q = Matrix(0.001 * I(d))
    x0 = zeros(d)
    P0 = Matrix(0.001 * I(d))
    
    # Define observation parameters separately for each state
    B = Vector{LinearDynamicalSystem}(undef, K)
    
    # Generate state matrices with different dynamics for each state
    for k in 1:K
        # Create rotation angles for each 2D subspace in the state space
        F = Matrix{Float64}(I, d, d)
        
        # Parameter to make each state model unique
        angle_factor = 2π * (k-1) / K
        
        # Add rotation components in 2D subspaces
        for i in 1:2:d-1
            if i+1 <= d  # Ensure we have a pair
                # Create a 2D rotation with different angles for each state
                theta = 0.1 + angle_factor + (i-1)*0.2
                rotation = 0.95 * [cos(theta) -sin(theta); sin(theta) cos(theta)]
                F[i:i+1, i:i+1] = rotation
            end
        end
        
        # If d is odd, add a scaling factor to the last dimension
        if d % 2 == 1
            F[d, d] = 0.95
        end
        
        # Create state model with the designed dynamics
        state_model = GaussianStateModel(F, Q, x0, P0)
        
        # Observation matrix - random for each state
        C = randn(p, d)
        R = Matrix(0.001 * I(p))
        obs_model = GaussianObservationModel(C, R)
        
        # Create linear dynamical system for this state
        B[k] = LinearDynamicalSystem(state_model, obs_model, d, p, fill(true, 6))
    end
    
    return SwitchingLinearDynamicalSystem(A, B, πₖ, K)
end

"""
    fit!(slds::SwitchingLinearDynamicalSystem, y::Matrix{T}; 
         max_iter::Int=1000, 
         tol::Real=1e-12, 
         ) where {T<:Real}

Fit a Switching Linear Dynamical System using the variational Expectation-Maximization (EM) algorithm with Kalman smoothing.

# Arguments
- `slds::SwitchingLinearDynamicalSystem`: The Switching Linear Dynamical System to be fitted.
- `y::Matrix{T}`: Observed data, size (obs_dim, T_steps).

# Keyword Arguments
- `max_iter::Int=1000`: Maximum number of EM iterations.
- `tol::Real=1e-12`: Convergence tolerance for log-likelihood change.

# Returns
- `mls::Vector{T}`: Vector of log-likelihood values for each iteration.
- `param_diff::Vector{T}`: Vector of parameter differences over each iteration. 
- `FB::ForwardBackward`: ForwardBackward struct 
- `FS::FilterSmooth`: FilterSmooth struct 
"""
function fit!(
    slds::AbstractHMM, y::AbstractMatrix{T}; max_iter::Int=1000, tol::Real=1e-3
)where {T<:Real}

    # Initialize log-likelihood
    prev_ml = -T(Inf)

    # Create a vector to store the log-likelihood values
    mls = Vector{T}()
    param_diff = Vector{T}()

    sizehint!(mls, max_iter)  # Pre-allocate for efficiency

    prog = Progress(
        max_iter; desc="Fitting SLDS via vEM...", barlen=50, showspeed=true
    )

    K = slds.K
    T_step = size(y, 2)
    
    # INIT THE FILTER SMOOTH AND FB STRUCTS
    FB = initialize_forward_backward(slds, T_step, T)
    FS = [initialize_FilterSmooth(slds.B[k], T_step) for k in 1:K]

    # From the paper, we initialize the parameters by running the Kalman Smoother for each model. I would assume we need to set the initial hₜ as well.
    FB.γ = log.(ones(size(y)) * 0.5)

    # Run the Kalman Smoother for each model
    for k in 1:slds.K
      #3. compute xs from hs
      FS[k].x_smooth, FS[k].p_smooth, inverse_offdiag, total_entropy = smooth(slds.B[k], y, exp.(FB.γ[k,:]))
      FS[k].E_z, FS[k].E_zz, FS[k].E_zz_prev =
          sufficient_statistics(reshape(FS[k].x_smooth, size(FS[k].x_smooth)..., 1),
          reshape(FS[k].p_smooth, size(FS[k].p_smooth)..., 1),
          reshape(inverse_offdiag, size(inverse_offdiag)..., 1))
    end

    # Run EM
    for i in 1:max_iter
        # E-step
        ml, _ = variational_expectation!(slds, y, FB, FS)       

        # M-step
        Δparams = mstep!(slds, FS, y, FB)
    
        # Update the log-likelihood vector and parameter difference
        push!(mls, ml)
        push!(param_diff, Δparams)

        # Update the progress bar
        next!(prog)

        # Check convergence
        if abs(ml - prev_ml) < tol
            finish!(prog)
            return mls, param_diff, FB, FS
        end

        prev_ml = ml
    end

    # Finish the progress bar if max_iter is reached
    finish!(prog)

    return mls, param_diff, FB, FS
end

"""
    variational_expectation!(model::SwitchingLinearDynamicalSystem, y, FB, FS) -> Float64

Compute the variational expectation (Evidence Lower Bound, ELBO) for a Switching Linear Dynamical System by executing the following operations: 

1. **Extract Responsibilities**:  
   Retrieves the responsibilities (`γ`) from the forward-backward object and computes their exponentials (`hs`).

2. **Parallel Smoothing and Sufficient Statistics Calculation**:  
   For each regime `k` from `1` to `model.K`, the function:
   - Performs smoothing using the `smooth` function to obtain smoothed states (`x_smooth`), covariances (`p_smooth`), inverse off-diagonal terms, and total entropy.
   - Computes sufficient statistics (`E_z`, `E_zz`, `E_zz_prev`) from the smoothed estimates.
   - Calculates the ELBO contribution for the current regime and accumulates it into `ml_total`.

3. **Update Variational Distributions**:  
   - Computes the variational distributions (`qs`) from the smoothed states, which are stored as log-likelihoods in `FB`.
   - Executes the forward and backward passes to update the responsibilities (`γ`) based on the new `qs`.
   - Recalculates the responsibilities (`γ`) to reflect the updated variational distributions.

4. **Return ELBO**:  
   Returns the accumulated ELBO (`ml_total`), which quantifies the quality of the variational approximation.
"""
function variational_expectation!(
  model::SwitchingLinearDynamicalSystem, 
  y::AbstractMatrix{T}, 
  FB::ForwardBackward, 
  FS::Vector{FilterSmooth{T}}) where {T<:Real}
  # For now a hardcoded tolerance
  tol = 1e-6
  # Get starting point for iterative E-step
  γ = FB.γ
  hs = exp.(γ)
  ml_total = 0.
  # Initialize to something higher than the tolerance
  ml_diff = 1
  ml_prev = -Inf
  ml_storage = []
  
  while abs(ml_diff) > tol  # Changed to use absolute value
      #1. compute qs from xs, which will live as log_likelihoods in FB
      variational_qs!([model.obs_model for model in model.B], FB, y, FS)
      
      #2. compute hs from qs, which will live as γ in FB
      forward!(model, FB)
      backward!(model, FB)
      calculate_γ!(model, FB)
      calculate_ξ!(model, FB)   # needed for m_step update of transition matrix
      hs = exp.(FB.γ)
      ml_total = 0.0
      # ml_total = logsumexp(FB.α[:, end])

      # elbo from the discret state model
      hmm_contribution = hmm_elbo(model, FB)
      ml_total += hmm_contribution
      
      for k in 1:model.K
          #3. compute xs from hs
          FS[k].x_smooth, FS[k].p_smooth, inverse_offdiag, total_entropy = smooth(model.B[k], y, vec(hs[k,:]))
          FS[k].E_z, FS[k].E_zz, FS[k].E_zz_prev =
              sufficient_statistics(reshape(FS[k].x_smooth, size(FS[k].x_smooth)..., 1),
              reshape(FS[k].p_smooth, size(FS[k].p_smooth)..., 1),
              reshape(inverse_offdiag, size(inverse_offdiag)..., 1))

          # Calculate the ELBO contribution for the current SSM
          elbo = calculate_elbo(model.B[k], FS[k].E_z, FS[k].E_zz, FS[k].E_zz_prev, reshape(FS[k].p_smooth, (size(FS[k].p_smooth)..., 1)), reshape(y, (size(y)..., 1)), total_entropy, vec(hs[k,:]))
          ml_total += elbo
      end
     
      push!(ml_storage, ml_total)

      # Calculate difference between current and previous ml_total
      ml_diff = ml_total - ml_prev  # Changed order of subtraction
      ml_prev = ml_total
  end
  
  return ml_total, ml_storage
end

"""
    hmm_elbo(model::AbstractHMM, FB::ForwardBackward; ϵ::Float64=1e-10)

Compute the evidence based lower bound (ELBO) from the discrete state model. 
"""
function hmm_elbo(model::AbstractHMM, FB::ForwardBackward; ϵ::Float64=1e-10)
  # Extract necessary data
  γ = FB.γ
  ξ = FB.ξ
  loglikelihoods = FB.loglikelihoods
  A = model.A   # Transition matrix
  πₖ = model.πₖ # Initial state distribution
  time_steps = size(loglikelihoods, 2)
  
  # Apply small epsilon to avoid log(0)
  safe_A = clamp.(A, ϵ, 1.0)
  safe_πₖ = clamp.(πₖ, ϵ, 1.0)
  
  # Initial state probabilities
  log_p_x_z = sum(exp.(γ[:, 1]) .* log.(safe_πₖ))
  
  # Transition term using ξ
  for t in 1:(time_steps - 1)
    log_p_x_z += sum(exp.(ξ[:, :, t]) .* log.(safe_A))
  end
  
  # Emission term
  log_p_x_z += sum(exp.(γ) .* loglikelihoods)
  
  # 2. Compute log q(z)
  # Here too we need to avoid log(0) for γ entries
  safe_γ = clamp.(γ, -log(1/ϵ), log(1/ϵ))  # Limit extremes in log space
  log_q_z = sum(exp.(γ) .* safe_γ)
  
  log_p_x_z - log_q_z
end

"""
  variational_qs!(model::AbstractVector{<:GaussianObservationModel{T, <:AbstractMatrix{T}}}, 
  FB::ForwardBackward, y::AbstractMatrix{T}, FS::Vector{FilterSmooth{T}}) where {T<:Real}

Compute the variational distributions (`qs`) and update the log-likelihoods for a set of Gaussian observation models within a Forward-Backward framework.
"""
function variational_qs!(
  model::AbstractVector{<:GaussianObservationModel{T, <:AbstractMatrix{T}}}, 
  FB::ForwardBackward, 
  y::AbstractMatrix{T}, 
  FS::Vector{FilterSmooth{T}}) where {T<:Real}

  T_steps = size(y, 2)
  K = length(model)

    @threads for k in 1:K

        R_chol = cholesky(Symmetric(model[k].R))
        C = model[k].C

        @views @inbounds for t in 1:T_steps
          FB.loglikelihoods[k, t] = -0.5 * tr(R_chol \ Q_obs(C, FS[k].E_z[:, t, 1], FS[k].E_zz[:, :, t, 1], y[:, t]))
        end
    end 
end


"""
    mstep!(slds::AbstractHMM, FS::Vector{FilterSmooth{T}}, y::AbstractMatrix{T}, FB::ForwardBackward) where {T<:Real}

Function to carry out the M-step in Expectation-Maximization algorithm for SLDS 
"""
function mstep!(slds::AbstractHMM,
    FS::Vector{FilterSmooth{T}}, 
    y::AbstractMatrix{T}, 
    FB::ForwardBackward) where {T<:Real}

    K = slds.K

    #update initial state distribution
    update_initial_state_distribution!(slds, FB)
    #update transition matrix
    update_transition_matrix!(slds, FB)

    γ = FB.γ
    hs = exp.(γ)

    # get initial parameters
    old_params = vec([stateparams(slds.B[k]) for k in 1:K])
    old_params = [old_params; vec([obsparams(slds.B[k]) for k in 1:K])]

    for k in 1:K
        # Update LDS parameters
        update_initial_state_mean!(slds.B[k], FS[k].E_z)
        update_initial_state_covariance!(slds.B[k], FS[k].E_z, FS[k].E_zz)
        update_A!(slds.B[k], FS[k].E_zz, FS[k].E_zz_prev)
        update_Q!(slds.B[k], FS[k].E_zz, FS[k].E_zz_prev)
        update_C!(slds.B[k], FS[k].E_z, FS[k].E_zz, reshape(y, size(y)...,1), vec(hs[k,:]))

        # In this case, we are not updating R. Empirically we have found this matrix causes numerical instability, and we can fix without loss of generality. In future, we can search for alternative estiamtors for R. 
        # update_R!(slds.B[k], FS[k].E_z, FS[k].E_zz, reshape(y, size(y)...,1), vec(hs[k,:]))
    end

    new_params = vec([stateparams(slds.B[k]) for k in 1:K])
    new_params = [new_params; vec([obsparams(slds.B[k]) for k in 1:K])]

    # calculate norm of parameter changes
    norm_change = norm(new_params - old_params)
    return norm_change
end