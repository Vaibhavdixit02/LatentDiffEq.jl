# Latent ODE model
#
# Based on
# https://arxiv.org/abs/1806.07366
# https://arxiv.org/abs/2003.10775

struct LatentODE <: LatentDE end

apply_feature_extractor(encoder::Encoder{LatentODE}, x) = encoder.feature_extractor.(x)

function apply_pattern_extractor(encoder::Encoder{LatentODE}, fe_out)
    pe_z₀ = encoder.pattern_extractor

    # reverse sequence
    fe_out_rev = reverse(fe_out)

    # pass it through the recurrent layers
    pe_out = map(pe_z₀, fe_out_rev)[end]

    # reset hidden states
    Flux.reset!(pe_z₀)

    return pe_out
end

function apply_latent_in(encoder::Encoder{LatentODE}, pe_out)
    li_μ_z₀, li_logσ²_z₀ = encoder.latent_in

    z₀_μ = li_μ_z₀(pe_out)
    z₀_logσ² = li_logσ²_z₀(pe_out)

    return z₀_μ, z₀_logσ²
end

apply_latent_out(decoder::Decoder{LatentODE}, z̃₀) = decoder.latent_out(z̃₀)

function diffeq_layer(decoder::Decoder{LatentODE}, ẑ₀, t)
    dudt = decoder.diffeq.dudt
    solver = decoder.diffeq.solver
    neural_model = decoder.diffeq.neural_model
    augment_dim = decoder.diffeq.augment_dim
    kwargs = decoder.diffeq.kwargs
    # sensealg = decoder.diffeq.sensealg

    # nODE = neural_model(dudt, (t[1], t[end]), solver, sensealg = sensealg, saveat = t)
    nODE = neural_model(dudt, (t[1], t[end]), solver; saveat = t, kwargs...)
    nODE = augment_dim == 0 ? nODE : AugmentedNDELayer(nODE, augment_dim)
    ẑ = Array(nODE(ẑ₀))

    # Transform the resulting output (mainly used for Kuramoto-like systems)
    ẑ = transform_after_diffeq(ẑ, decoder.diffeq)
    ẑ = Flux.unstack(ẑ, 3)

    return ẑ
end

apply_reconstructor(decoder::Decoder{LatentODE}, ẑ) = decoder.reconstructor.(ẑ)

function sample(μ::T, logσ²::T, model::LatentDiffEqModel{LatentODE}) where T <: Array
    z₀_μ = μ
    z₀_logσ² = logσ²

    ẑ₀ = z₀_μ + randn(Float32, size(z₀_logσ²)) .* exp.(z₀_logσ²/2f0)

    return ẑ₀
end

function sample(μ::T, logσ²::T, model::LatentDiffEqModel{LatentODE}) where T <: Flux.CUDA.CuArray
    z₀_μ = μ
    z₀_logσ² = logσ²

    ẑ₀ = z₀_μ + gpu(randn(Float32, size(z₀_logσ²))) .* exp.(z₀_logσ²/2f0)

    return ẑ₀
end

function default_layers(model_type::LatentODE, input_dim, diffeq; device = cpu,
                            hidden_dim_resnet = 200, rnn_input_dim = 32,
                            rnn_output_dim = 32, latent_to_diffeq_dim = 200,
                            output_activation = σ)
    
    latent_dim_in = diffeq.latent_dim_in
    latent_dim_out = diffeq.latent_dim_out

    ######################
    ### Encoder layers ###
    ######################

    # Resnet
    l1 = Dense(input_dim, hidden_dim_resnet, relu)
    l2 = Dense(hidden_dim_resnet, hidden_dim_resnet, relu)
    l3 = Dense(hidden_dim_resnet, hidden_dim_resnet, relu)
    l4 = Dense(hidden_dim_resnet, rnn_input_dim, relu)
    feature_extractor = Chain(l1,
                                SkipConnection(l2, +),
                                SkipConnection(l3, +),
                                l4) |> device

    # RNN
    pattern_extractor = Chain(RNN(rnn_input_dim, rnn_output_dim, relu),
                                RNN(rnn_output_dim, rnn_output_dim, relu)) |> device

    # final fully connected layers before sampling
    li_μ_z₀ = Dense(rnn_output_dim, latent_dim_in) |> device
    li_logσ²_z₀ = Dense(rnn_output_dim, latent_dim_in) |> device

    latent_in = (li_μ_z₀, li_logσ²_z₀)

    encoder_layers = (feature_extractor, pattern_extractor, latent_in)

    ######################
    ### Decoder layers ###
    ######################

    # going back to the input dimensions
    # Resnet
    l1 = Dense(latent_dim_out, hidden_dim_resnet, relu)
    l2 = Dense(hidden_dim_resnet, hidden_dim_resnet, relu)
    l3 = Dense(hidden_dim_resnet, hidden_dim_resnet, relu)
    l4 = Dense(hidden_dim_resnet, input_dim, output_activation)
    reconstructor = Chain(l1,
                            SkipConnection(l2, +),
                            SkipConnection(l3, +),
                            l4)  |> device

    decoder_layers = (x -> x, diffeq, reconstructor)
    
    return encoder_layers, decoder_layers
end