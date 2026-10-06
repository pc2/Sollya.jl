@testset "Exact constants and ownership" begin
    with_session(Session(; precision = 20)) do
        with_objects() do keep
            for value in (
                0,
                -3,
                typemin(Int64),
                typemax(Int64),
                typemax(UInt64),
                (big(1) << 2000) + 17,
                -(big(1) << 90),
                3 // 5,
                (big(1) + (big(1) << 347) + (big(1) << 400)) // (big(1) << 400),
                Float16(0.1),
                Float32(0.1),
                0.1,
                -0.0,
            )
                obj = keep(SollyaObject(value))
                @test exact_rational(obj) == Rational{BigInt}(value)
                @test exact_rational(keep(sollya(expression(obj)))) ==
                      Rational{BigInt}(value)
            end
            value = setprecision(BigFloat, 512) do
                BigFloat(1) + ldexp(BigFloat(1), -400)
            end
            @test exact_rational(keep(SollyaObject(value))) ==
                  ((big(1) << 400) + 1) // (big(1) << 400)
            for text in ("[1;2]", "[1;1]", "exp(pi)+log(2)", "x", "NaN", "infty")
                @test_throws SollyaError exact_rational(keep(sollya(text)))
            end
            obj = keep(sollya"13/4")
            @test parse(SollyaObject, "13/4") |> keep |> exact_rational == 13 // 4
            @test Float64(obj) == 3.25
            @test convert(Rational{BigInt}, obj) == 13 // 4
            @test convert(Float64, obj) == 3.25
            @test_throws ArgumentError serialize(IOBuffer(), obj)
            duplicate = keep(copy(obj))
            close(obj)
            close(obj)
            @test !isopen(obj)
            @test occursin("closed", repr(obj))
            @test exact_rational(duplicate) == 13 // 4
            @test_throws ArgumentError exact_rational(obj)
            @test_throws ArgumentError copy(obj)
            @test_throws ArgumentError sollya("1\0+2")
            @test_throws SollyaError sollya("this is invalid syntax ]")
        end
    end
end

@testset "Julia irrational constants import symbolically" begin
    for (value, alias, text) in (
        (π, pi, "pi"),
        (ℯ, Base.MathConstants.e, "exp(1)"),
        (Base.MathConstants.φ, Base.MathConstants.golden, "(1+sqrt(5))/2"),
    )
        with_session() do
            with_objects() do keep
                p = with_session(Session(; precision = 12)) do
                    setprecision(BigFloat, 32) do
                        setrounding(BigFloat, RoundUp) do
                            obj = keep(SollyaObject(value))
                            @test expression(obj) == expression(keep(sollya(text)))
                            @test structurally_equal(obj, keep(sollya(text)))
                            @test_throws SollyaError exact_rational(obj)
                            @test_throws SollyaError BigFloat(obj)
                            @test precision(BigFloat) == 32
                            @test rounding(BigFloat) == RoundUp
                            @test working_precision() == 12
                            obj
                        end
                    end
                end
                # Parsing can combine φ / 2 into (1 + sqrt(5)) / 4.
                @test bounds(keep(interval(keep(p / 2)))) ==
                      bounds(keep(interval(keep(sollya("($text)/2")))))
                x = keep(variable())
                for (result, expected_text) in (
                    (keep(value * x), "($text)*x"),
                    (keep(x + value), "x+($text)"),
                    (keep(value - x), "($text)-x"),
                    (keep(x / value), "x/($text)"),
                    (keep(x^value), "x^($text)"),
                    (keep(value^x), "($text)^x"),
                )
                    expected = keep(sollya(expected_text))
                    @test structurally_equal(result, expected)
                    @test bounds(keep(enclosure(result, 2))) ==
                          bounds(keep(enclosure(expected, 2)))
                end
                @test structurally_equal(keep(value .+ x), keep(sollya("($text)+x")))
                with_session(Session(; precision = 512)) do
                    # A low-precision import must still enclose the high-precision constant.
                    lo, hi = bounds(BigFloat, keep(interval(p)); precision = 512)
                    # Julia evaluates ℯ and φ through elementary operations;
                    # use directed rounding with guard bits for reference bounds.
                    reference_lo = setrounding(BigFloat, RoundDown) do
                        BigFloat(value; precision = 640)
                    end
                    reference_hi = setrounding(BigFloat, RoundUp) do
                        BigFloat(value; precision = 640)
                    end
                    @test lo <= reference_lo < reference_hi <= hi
                    @test hi - lo < big(1) // (big(1) << 500)
                    lower, upper =
                        bounds(BigFloat, keep(interval(0, value)); precision = 512)
                    @test lower == 0
                    @test reference_hi <= upper
                end
                duplicate = keep(SollyaObject(alias))
                dependent = keep(p * x)
                close(p)
                @test structurally_equal(duplicate, keep(sollya(text)))
                @test structurally_equal(dependent, keep(sollya("($text)*x")))
                @test bounds(keep(enclosure(dependent, 2))) ==
                      bounds(keep(interval(keep(2 * duplicate))))
                @test_throws ArgumentError ApproximationRequest("sin(x)", (0, value))
            end
        end
    end
    @test_throws MethodError SollyaObject(Base.MathConstants.eulergamma)
    @test_throws MethodError SollyaObject(Base.MathConstants.catalan)
end

@testset "Scoped object cleanup" begin
    registered = SollyaObject[]
    result = with_objects() do keep
        obj = keep(SollyaObject(1 // 3))
        push!(registered, obj)
        @test keep(obj) === obj
        temporary = keep(obj + 1)
        push!(registered, temporary)
        close(temporary)
        @test !isopen(temporary)
        exact_rational(obj)
    end
    @test result == 1 // 3
    @test all(obj -> !isopen(obj), registered)
    @test with_objects(_ -> 42) == 42

    failure = ErrorException("intentional scoped failure")
    seen = Ref{SollyaObject}()
    caught = try
        with_objects() do keep
            seen[] = keep(SollyaObject(7))
            throw(failure)
        end
    catch err
        err
    end
    @test caught === failure
    @test !isopen(seen[])

    returned = with_objects(keep -> keep(SollyaObject(2)))
    @test !isopen(returned)
    expired = with_objects(identity)
    with_objects() do keep
        original = keep(SollyaObject(5))
        retained = keep(with_objects() do inner
            scoped = inner(copy(original))
            seen[] = scoped
            copy(scoped)
        end)
        @test !isopen(seen[])
        @test exact_rational(original) == 5
        @test exact_rational(retained) == 5
        @test_throws ArgumentError expired(original)
        @test isopen(original)
        @test_throws MethodError keep(5)

        other_task_error = fetch(Threads.@spawn try
            keep(original)
        catch err
            err
        end)
        @test other_task_error isa ArgumentError
        @test isopen(original)
        task = Threads.@spawn with_objects() do inner
            obj = inner(SollyaObject(9))
            (exact_rational(obj), obj)
        end
        value, closed = fetch(task)
        @test value == 9
        @test !isopen(closed)
        close(original)
        @test_throws ArgumentError keep(original)
    end
end

@testset "BigFloat imports preserve the stored value" begin
    expected = ((big(1) << 400) + 1) // (big(1) << 400)
    cases = setprecision(BigFloat, 512) do
        value = BigFloat(1) + ldexp(BigFloat(1), -400)
        (
            value => expected,
            -value => -expected,
            prevfloat(BigFloat(1)) => ((big(1) << 512) - 1) // (big(1) << 512),
            ldexp(value, 2000) => expected * (big(1) << 2000),
            ldexp(-value, -2000) => -expected // (big(1) << 2000),
            BigFloat(0) => 0 // 1,
            BigFloat(-0.0) => 0 // 1,
        )
    end
    with_session(Session(; precision = 20)) do
        with_objects() do keep
            for bits in (64, 1024), mode in (RoundNearest, RoundDown, RoundUp, RoundToZero)
                setprecision(BigFloat, bits) do
                    setrounding(BigFloat, mode) do
                        for (value, rational) in cases
                            @test exact_rational(keep(SollyaObject(value))) == rational
                        end
                        @test precision(BigFloat) == bits
                        @test rounding(BigFloat) == mode
                    end
                end
            end
            for value in (BigFloat(Inf), BigFloat(-Inf), BigFloat(NaN))
                @test isequal(Float64(keep(SollyaObject(value))), Float64(value))
            end
        end
    end
end

@testset "BigFloat export rounds finite rational constants" begin
    with_session(Session(; precision = 20)) do
        with_objects() do keep
            modes = (RoundNearest, RoundDown, RoundUp, RoundToZero, RoundFromZero)
            for (value, expected) in (
                (11 // 13, (7 // 8, 3 // 4, 7 // 8, 3 // 4, 7 // 8)),
                (-11 // 13, (-7 // 8, -7 // 8, -3 // 4, -3 // 4, -7 // 8)),
                (9 // 8, (1, 1, 5 // 4, 1, 5 // 4)),
                (11 // 8, (3 // 2, 5 // 4, 3 // 2, 5 // 4, 3 // 2)),
                (0, (0, 0, 0, 0, 0)),
            )
                obj = keep(SollyaObject(value))
                for (mode, wanted) in zip(modes, expected)
                    result = BigFloat(obj, mode; precision = 3)
                    @test result == wanted
                    @test precision(result) == 3
                end
            end
            setprecision(BigFloat, 64) do
                setrounding(BigFloat, RoundUp) do
                    for value in (
                        ((big(1) << 400) + 1) // (big(1) << 400),
                        (big(1) << 2000) + (big(1) << 1600),
                        big(1) // (big(1) << 2000),
                    )
                        obj = keep(SollyaObject(value))
                        result = BigFloat(obj, RoundNearest; precision = 512)
                        @test precision(result) == 512
                        @test exact_rational(keep(SollyaObject(result))) == value
                        @test isopen(obj)
                    end
                    obj = keep(SollyaObject(11 // 13))
                    result = BigFloat(obj)
                    @test precision(result) == 64
                    @test exact_rational(keep(SollyaObject(prevfloat(result)))) <
                          11 // 13 <
                          exact_rational(keep(SollyaObject(result)))
                    @test convert(BigFloat, obj) == result
                    @test BigFloat[obj] == [result]
                    @test BigFloat(obj, RoundDown; precision = 3) == 3 // 4
                    @test BigFloat(obj, RoundNearest; precision = 1) == 1
                    @test precision(BigFloat) == 64
                    @test rounding(BigFloat) == RoundUp
                end
            end
            @test working_precision() == 20
            obj = keep(SollyaObject(1 // 3))
            @test_throws DomainError BigFloat(obj; precision = 0)
            @test_throws ArgumentError BigFloat(obj, RoundNearestTiesAway)
            for text in ("pi", "x", "[1;1]", "NaN", "infty", "-infty")
                @test_throws SollyaError BigFloat(keep(sollya(text)))
            end
            close(obj)
            @test_throws ArgumentError BigFloat(obj)
        end
    end
end

@testset "Settings restored on success and failure" begin
    original = working_precision()
    settings() =
        with_objects() do keep
            (
                exact_rational(keep(sollya("verbosity"))),
                exact_rational(keep(sollya("points"))),
                exact_rational(keep(sollya("diam"))),
            )
        end
    previous_settings = settings()
    for bits in (128, 384)
        with_session(Session(; precision = bits, points = 64, diameter = 1 // 1024)) do
            @test working_precision() == bits
            with_session(Session(; precision = 64)) do
                @test working_precision() == 64
            end
            @test working_precision() == bits
        end
        @test working_precision() == original
        @test settings() == previous_settings
    end
    @test_throws ErrorException with_session(Session(; precision = 512)) do
        @test working_precision() == 512
        error("intentional exception")
    end
    @test working_precision() == original
    @test settings() == previous_settings
    with_session(Session(; precision = 12, points = 3)) do
        @test working_precision() == 12
        @test settings()[2] == 3
    end
    for kwargs in (
        (; precision = 1),
        (; precision = 8),
        (; verbosity = -1),
        (; points = 1),
        (; points = 2),
        (; diameter = 0 // 1),
    )
        @test_throws ArgumentError Session(; kwargs...)
    end
end

@testset "Sessions capture BigFloat precision" begin
    original = working_precision()
    session = setprecision(BigFloat, 384) do
        @test Session().precision == 384
        @test Session(; precision = 128).precision == 128
        Session(; points = 64, diameter = 1 // 1024)
    end
    io = IOBuffer()
    serialize(io, session)
    seekstart(io)
    session = deserialize(io)
    setprecision(BigFloat, 64) do
        setrounding(BigFloat, RoundUp) do
            with_session(session) do
                @test working_precision() == 384
                with_objects() do keep
                    @test exact_rational(keep(sollya("points"))) == 64
                    @test exact_rational(keep(sollya("diam"))) == 1 // 1024
                end
                @test_throws ErrorException with_session() do
                    @test working_precision() == 64
                    error("intentional nested session failure")
                end
                @test working_precision() == 384
                @test precision(BigFloat) == 64
                @test rounding(BigFloat) == RoundUp
            end
            @test working_precision() == original
            @test precision(BigFloat) == 64
            @test rounding(BigFloat) == RoundUp
        end
    end
    setprecision(BigFloat, 12) do
        @test Session().precision == 12
    end
    setprecision(BigFloat, 8) do
        @test_throws ArgumentError Session()
        @test Session(; precision = 128).precision == 128
    end
    @test_throws ArgumentError Session(; points = 2)
    @test working_precision() == original
end

@testset "Lazy library discovery" begin
    code =
        "using Sollya; Session(); ApproximationRequest(\"exp(x)\", (0, 1)); " *
        "try; library_path(); error(\"expected missing library\"); " *
        "catch e; e isa ArgumentError || rethrow(); print(\"OK\"); end"
    project = dirname(@__DIR__)
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`
    mktempdir() do directory
        command =
            addenv(command, "SOLLYA_LIBRARY" => joinpath(directory, "missing-library"))
        @test read(command, String) == "OK"
    end
end

@testset "Finite lists own copies and indexed elements" begin
    with_objects() do keep
        x = keep(variable())
        input = keep(sin(x))
        list = keep(sollya_list([input, 7, 3 // 5]))
        close(input)
        @test islist(list)
        @test length(list) == 3
        @test equal(keep(list[1]), keep(sin(x)))
        @test exact_rational(keep(list[2])) == 7
        @test exact_rational(keep(list[3])) == 3 // 5
        @test_throws BoundsError list[0]
        @test_throws BoundsError list[4]
        empty = keep(sollya_list([]))
        @test length(empty) == 0
        @test isempty(collect(empty))
        @test_throws ArgumentError length(x)
        first = keep(list[1])
        close(list)
        @test equal(first, keep(sin(x)))
    end
end
