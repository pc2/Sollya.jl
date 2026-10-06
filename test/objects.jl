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

@testset "Lazy library discovery" begin
    code =
        "using Sollya; try; library_path(); error(\"expected missing library\"); " *
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
