
include("GOKU_model.jl")
include("utils.jl")
include("visualize.jl")

# arguments for the `train` function
@with_kw mutable struct Args

    ## Training params
    η = 1e-3                    # learning rate
    λ = 0.01f0                  # regularization paramater
    batch_size = 256            # minibatch size
    seq_len = 100               # sampling size for output
    epochs = 100                # number of epochs for training
    seed = 1                    # random seed
    cuda = false                # GPU usage
    t_span = (0.f0, 4.95f0)     # span of time interval for training
    start_af = 0.00001          # Annealing factor start value
    end_af = 0.00001            # Annealing factor end value
    ae = 200                    # Annealing factor epoch end

    ## Model dimensions
    input_dim = 2               # model input size
    ode_dim = 2                 # ode solve size
    p_dim = 4                   # number of parameter of system
    rnn_input_dim = 32          # rnn input dimension
    rnn_output_dim = 32         # rnn output dimension
    latent_dim = 4              # latent dimension
    hidden_dim = 120            # hidden dimension
    hidden_dim_node = 200       # hidden dimension of the neuralODE
    hidden_dim_gen = 10         # hidden dimension of the g function

    ## Data generation parameters
    full_t_span = (0.0, 19.95)  # full time span of training exemple (un-sequenced)
    dt = 0.05                   # timestep for ode solve
    u₀_range = (1.5, 3.0)       # initial value range
    p₀_range = (1.0, 2.0)       # parameter value range
    save_path = "output"        # results path
    data_file_name = "lv_data.bson"  # data file name
    raw_data_name = "raw_data"  # raw data name
    gen_data_name = "gen_data"  # generated data name
end

# TODO : train with incremental time addition i.e. https://sebastiancallh.github.io/post/neural-ode-weather-forecast/
# TODO : use sciML train function
function train(; kws...)

    # load hyperparamters
    args = Args(; kws...)
    args.seed > 0 && Random.seed!(args.seed)

    # GPU config
    if args.cuda && has_cuda_gpu()
        device = gpu
        @info "Training on GPU"
    else
        device = cpu
        @info "Training on CPU"
    end

    # load data from bson
    @load args.data_file_name raw_data # gen_data
    raw_data = Float32.(raw_data)
    input_dim, time_size, observations = size(raw_data)
    train_set, test_set = splitobs(raw_data, 0.9)
    train_set, val_set = splitobs(train_set, 0.9)

    # Initialize dataloaders
    loader_train = DataLoader(Array(train_set), batchsize=args.batch_size, shuffle=true, partial=false)
    loader_val = DataLoader(Array(val_set), batchsize=size(val_set, 3), shuffle=true, partial=false)

    # Define saving time steps
    t = range(args.t_span[1], args.t_span[2], length=args.seq_len)

    # initialize Goku-net object
    goku = Goku(args.input_dim, args.latent_dim, args.rnn_input_dim, args.rnn_output_dim, args.hidden_dim, args.ode_dim, args.p_dim, lv_func, Tsit5(), device)

    # ADAM optimizer
    opt = ADAM(args.η)

    # parameters
    ps = Flux.params(goku.encoder.linear, goku.encoder.rnn, goku.encoder.rnn_μ, goku.encoder.rnn_logσ², goku.encoder.lstm, goku.encoder.lstm_μ, goku.encoder.lstm_logσ², goku.decoder.z₀_linear, goku.decoder.p_linear, goku.decoder.gen_linear)

    mkpath(args.save_path)

    # training
    @info "Start Training, total $(args.epochs) epochs"
    for epoch = 1:args.epochs
        @info "Epoch $(epoch)"
        progress = Progress(length(loader_train))
        mb_id = 1 # TODO : implement a cleaner way of knowing minibatch ID, there must be some way to do it from the dataloader, but didn't find anything
        for x in loader_train
            loss, back = Flux.pullback(ps) do
                af = annealing_factor(args.start_af, args.end_af, args.ae, epoch, mb_id, length(loader_train))
                loss_batch(goku, args.λ, x |> device, t, af)
            end
            grad = back(1f0)
            Flux.Optimise.update!(opt, ps, grad)

            # progress meter
            next!(progress; showvalues=[(:loss, loss)])

            visualize_training(goku, x, t)
            mb_id += 1

        end

        model_path = joinpath(args.save_path, "model_epoch_$(epoch).bson")
        let encoder = cpu(goku.encoder),
            decoder = cpu(goku.decoder),
            args=struct2dict(args)

            BSON.@save model_path encoder decoder args
            @info "Model saved: $(model_path)"
        end
    end

    model_path = joinpath(args.save_path, "model.bson")
    let encoder = cpu(goku.encoder),
        decoder = cpu(goku.decoder),
        args=struct2dict(args)

        BSON.@save model_path encoder decoder args
        @info "Model saved: $(model_path)"
    end
end

const seq_len = 100

if abspath(PROGRAM_FILE) == @__FILE__
    train()
end
