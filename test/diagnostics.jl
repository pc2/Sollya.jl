# IDs and summaries follow sollya-messages.h and the message-callback contract
# in Sollya 8.0's manual and tests-lib/tmsg_callback_functions.c.
function caught_sollya_error(f)
    try
        result = f()
        result isa SollyaObject && close(result)
    catch err
        err isa SollyaError || rethrow()
        return err
    end
    error("expected a SollyaError")
end

function native_message_callback()
    Sollya._locked() do
        callback, data = Ref{Ptr{Cvoid}}(C_NULL), Ref{Ptr{Cvoid}}(C_NULL)
        ccall(
            Sollya._fn(:sollya_lib_get_msg_callback),
            Cvoid,
            (Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
            callback,
            data,
        )
        (callback[], data[])
    end
end

function count_native_message(::Ptr{Cvoid}, data::Ptr{Cvoid})::Cint
    counter = Ptr{Cint}(data)
    unsafe_store!(counter, unsafe_load(counter) + Cint(1))
    return Cint(0)
end

@testset "Native failure diagnostics" begin
    previous_callback = native_message_callback()
    plain = SollyaError(:test, "plain failure")
    @test isempty(plain.diagnostics)
    @test sprint(showerror, plain) == "Sollya test: plain failure"
    with_session() do
        with_objects() do keep
            f = keep(sollya("exp(x)"))
            domain = keep(interval(0, 1))
            for (operation, run) in (
                (:supnorm, () -> supnorm(f, f, domain)),
                (:fpminimax, () -> fpminimax(f, 3, :single, domain; minimax = f)),
                (:remez, () -> remez(f, 3, domain; weight = domain)),
            )
                err = caught_sollya_error(run)
                @test err.operation == operation
                @test !isempty(err.diagnostics)
                @test all(item -> first(item) > 0 && !isempty(last(item)), err.diagnostics)
                @test length(err.diagnostics) <= 16
                @test occursin(last(first(err.diagnostics)), sprint(showerror, err))
                if operation == :supnorm
                    @test (29 => "The given function is no polynomial") in err.diagnostics
                end
                io = IOBuffer()
                serialize(io, err)
                seekstart(io)
                @test deserialize(io).diagnostics == err.diagnostics
                @test native_message_callback() == previous_callback
                @test exact_rational(keep(sollya("verbosity"))) == 0
            end
            # Success must restore state too, and must not leave stale warnings.
            keep(fpminimax(f, 3, :single, domain))
            @test exact_rational(keep(sollya("verbosity"))) == 0
            @test native_message_callback() == previous_callback
            syntax = caught_sollya_error(() -> sollya("invalid expression ]"))
            @test syntax.operation == :parse
            @test occursin(repr("invalid expression ]"), syntax.detail)
            @test isempty(syntax.diagnostics)
            literal = caught_sollya_error(() -> sollya("error"))
            @test isempty(literal.diagnostics)
            long_input = repeat(" ", 300) * "]"
            long_error = caught_sollya_error(() -> sollya(long_input))
            @test length(long_error.detail) < 300
            @test endswith(long_error.detail, "…")
            mktemp() do path, io
                redirect_stdout(io) do
                    caught_sollya_error(() -> supnorm(f, f, domain))
                    Base.Libc.flush_cstdio()
                end
                flush(io)
                @test isempty(read(path, String))
            end
        end
    end
end

@testset "Existing message callbacks are preserved" begin
    callback = @cfunction(count_native_message, Cint, (Ptr{Cvoid}, Ptr{Cvoid}))
    counter = Ref{Cint}(0)
    Sollya._locked() do
        previous = native_message_callback()
        GC.@preserve counter begin
            data = Ptr{Cvoid}(Base.unsafe_convert(Ptr{Cint}, counter))
            try
                @test ccall(
                    Sollya._fn(:sollya_lib_install_msg_callback),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    callback,
                    data,
                ) == 1
                with_session(Session(; verbosity = 1)) do
                    err = caught_sollya_error(() -> sollya("invalid expression ]"))
                    @test any(item -> first(item) == 281, err.diagnostics)
                    @test counter[] > 0
                    @test native_message_callback() == (callback, data)
                    close(sollya("1/3"))
                    @test native_message_callback() == (callback, data)
                end
                with_session() do
                    calls = counter[]
                    with_objects() do keep
                        f = keep(sollya("exp(x)"))
                        domain = keep(interval(0, 1))
                        err = caught_sollya_error(() -> supnorm(f, f, domain))
                        @test isempty(err.diagnostics)
                    end
                    @test counter[] == calls
                    @test native_message_callback() == (callback, data)
                end
            finally
                if previous[1] == C_NULL
                    ccall(Sollya._fn(:sollya_lib_uninstall_msg_callback), Cint, ())
                else
                    ccall(
                        Sollya._fn(:sollya_lib_install_msg_callback),
                        Cint,
                        (Ptr{Cvoid}, Ptr{Cvoid}),
                        previous[1],
                        previous[2],
                    )
                end
            end
        end
    end
end

@testset "Diagnostics stay within their thread and operation" begin
    tasks = map(1:8) do index
        Threads.@spawn with_session() do
            if isodd(index)
                with_objects() do keep
                    f = keep(sollya("exp(x)"))
                    domain = keep(interval(0, 1))
                    caught_sollya_error(() -> supnorm(f, f, domain))
                end
            else
                caught_sollya_error(() -> sollya("error"))
            end
        end
    end
    for (index, err) in enumerate(fetch.(tasks))
        @test isodd(index) ? any(item -> first(item) == 29, err.diagnostics) :
              isempty(err.diagnostics)
    end
end
