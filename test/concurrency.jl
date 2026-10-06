@testset "Thread serialization and deferred finalization" begin
    original = working_precision()
    tasks = map((128, 192, 256, 384)) do bits
        Threads.@spawn with_session(Session(; precision = bits)) do
            for k = 1:50
                obj = SollyaObject((big(1) << k) + bits)
                @test exact_rational(obj) == (big(1) << k) + bits
                @test working_precision() == bits
                # Explicit finalization exercises deferred frees, even when the
                # callback is already holding the process-wide native lock.
                finalize(obj)
                @test !isopen(obj)
            end
            bits
        end
    end
    @test fetch.(tasks) == (128, 192, 256, 384)
    @test working_precision() == original
    GC.gc(true)
    drain_finalizers!()
    obj = SollyaObject(17)
    @test exact_rational(obj) == 17
    close(obj)
end

@testset "Concurrent BigFloat conversion settings" begin
    original = (precision(BigFloat), rounding(BigFloat))
    with_objects() do keep
        obj = keep(SollyaObject(11 // 13))
        cases = (
            (3, RoundDown, 3 // 4),
            (4, RoundUp, 7 // 8),
            (5, RoundToZero, 27 // 32),
            (6, RoundUp, 55 // 64),
        )
        tasks = map(cases) do (bits, mode, _)
            Threads.@spawn BigFloat(obj, mode; precision = bits)
        end
        for ((bits, _, expected), result) in zip(cases, fetch.(tasks))
            @test result == expected
            @test precision(result) == bits
        end
    end
    @test (precision(BigFloat), rounding(BigFloat)) == original
end

@testset "Concurrent BigFloat bounds settings" begin
    original = (precision(BigFloat), rounding(BigFloat), working_precision())
    with_objects() do keep
        domain = keep(interval(33 // 32))
        cases = (
            (3, (1, 5 // 4)),
            (4, (1, 9 // 8)),
            (5, (1, 17 // 16)),
            (6, (33 // 32, 33 // 32)),
        )
        tasks = map(cases) do (bits, _)
            Threads.@spawn bounds(BigFloat, domain; precision = bits)
        end
        for ((bits, expected), result) in zip(cases, fetch.(tasks))
            @test result == expected
            @test precision.(result) == (bits, bits)
        end
    end
    @test (precision(BigFloat), rounding(BigFloat), working_precision()) == original
end

@testset "Concurrent BigFloat coefficient settings" begin
    original = (precision(BigFloat), rounding(BigFloat), working_precision())
    with_objects() do keep
        p = keep(sollya("11/13 + 11/13*x^2"))
        cases = (
            (3, RoundDown, 3 // 4),
            (4, RoundUp, 7 // 8),
            (5, RoundToZero, 27 // 32),
            (6, RoundUp, 55 // 64),
        )
        tasks = map(cases) do (bits, mode, _)
            Threads.@spawn coefficients(BigFloat, p, mode; precision = bits)
        end
        for ((bits, _, expected), result) in zip(cases, fetch.(tasks))
            @test result == [expected, 0, expected]
            @test precision.(result) == fill(bits, 3)
        end
    end
    @test (precision(BigFloat), rounding(BigFloat), working_precision()) == original
end

@testset "Serializable approximation jobs" begin
    request = ApproximationRequest("erf(x)", (0, 1 // 4); precision = 128)
    @test deserialize(IOBuffer(let io = IOBuffer()
        serialize(io, request)
        take!(io)
    end)).domain == request.domain
    result = approximate(request)
    @test result.domain == (0, 1 // 4)
    @test result.error == :absolute
    @test result.precision == 128
    @test 0 < result.norm_bound[1] <= result.norm_bound[2] < 1 // 100000000
    @test length(result.coefficients) == 6
    io = IOBuffer()
    serialize(io, result)
    seekstart(io)
    @test deserialize(io).coefficients == result.coefficients
    for kwargs in (
        (; basis = -1),
        (; basis = [2, 1]),
        (; formats = [:single]),
        (; error = :unknown),
        (; arithmetic = :fixed),
        (; precision = 1),
        (; accuracy = 0),
    )
        @test_throws ArgumentError ApproximationRequest("exp(x)", (0, 1); kwargs...)
    end
    @test_throws ArgumentError ApproximationRequest("exp(x)", (1, 0))
    for endpoint in (NaN, Inf, -Inf, BigFloat(NaN), BigFloat(Inf), 1 // 0, -1 // 0)
        @test_throws ArgumentError ApproximationRequest("exp(x)", (endpoint, 1))
        @test_throws ArgumentError ApproximationRequest("exp(x)", (0, endpoint))
    end
    @test ApproximationRequest("exp(x)", (BigFloat(0), BigFloat(0.5))).domain == (0, 1 // 2)
    fixed = approximate(
        ApproximationRequest(
            "sin(x)",
            (-1 // 32, 1 // 32);
            basis = 6,
            formats = 32,
            arithmetic = :fixed,
        ),
    )
    @test all(c -> denominator(c * (big(1) << 32)) == 1, fixed.coefficients)
end

@testset "Direct approximation calls" begin
    with_session(Session(; precision = 192)) do
        result = approximate(
            SubString(" exp(x) ", 2, 7),
            (BigFloat(0), BigFloat(1 // 8));
            basis = [0, 1, 2, 3],
            formats = 32,
            error = :relative,
            arithmetic = :fixed,
            precision = 160,
            accuracy = 1 // 128,
        )
        @test result isa ApproximationResult
        @test result.domain == (0, 1 // 8)
        @test result.error == :relative
        @test result.precision == 160
        @test length(result.coefficients) == 4
        @test all(c -> denominator(c * (big(1) << 32)) == 1, result.coefficients)
        @test 0 < result.norm_bound[1] <= result.norm_bound[2] < 1 // 1000000
        @test working_precision() == 192
        @test_throws ArgumentError approximate("exp(x)", (1, 0))
        @test_throws ArgumentError approximate("exp(x)", (0, 1); accuracy = 0)
        @test_throws SollyaError approximate("invalid expression ]", (0, 1))
        @test working_precision() == 192
    end
end

@testset "Requests preserve BigFloat endpoints and accuracy" begin
    lower, upper = setprecision(BigFloat, 512) do
        (prevfloat(BigFloat(1)), nextfloat(BigFloat(1)))
    end
    expected_lower = ((big(1) << 512) - 1) // (big(1) << 512)
    expected_upper = ((big(1) << 511) + 1) // (big(1) << 511)
    setprecision(BigFloat, 64) do
        request = ApproximationRequest("exp(x)", (lower, upper))
        @test request.domain == (expected_lower, expected_upper)
        @test_throws ArgumentError ApproximationRequest("exp(x)", (upper, lower))
        @test ApproximationRequest("exp(x)", (0, 1); accuracy = lower).accuracy ==
              expected_lower
        @test precision(BigFloat) == 64
    end
end

# Distributed uses localhost sockets. Set this only in environments that forbid
# socket creation; ordinary Pkg.test and CI always run the process tests.
if get(ENV, "SOLLYA_TEST_WORKERS", "true") == "true"
    @testset "Independent local worker processes" begin
        original = working_precision()
        previous_workers = Set(Distributed.workers())
        ids = Int[]
        SollyaPool(2) do pool
            append!(ids, pool.workers)
            @test length(ids) == 2
            @test length(unique(Distributed.remotecall_fetch(getpid, id) for id in ids)) ==
                  2
            requests = [
                ApproximationRequest("erf(x)", (0, 1 // 4); precision = bits) for
                bits in (128, 384, 192, 256)
            ]
            results = approximate_many(pool, requests)
            @test [r.precision for r in results] == [128, 384, 192, 256]
            @test all(r -> 0 < r.norm_bound[2] < 1 // 100000000, results)
            # fpminimax can choose different coefficients at different working
            # precisions; check each result's declared representation and proof.
            @test all(
                r -> all(c -> Rational{BigInt}(Float32(Float64(c))) == c, r.coefficients),
                results,
            )
            @test working_precision() == original
            @test isopen(pool)
            bad = ApproximationRequest("invalid expression ]", (0, 1))
            @test_throws Exception approximate_many(pool, [bad])
            @test length(approximate_many(pool, [requests[1]])) == 1
            close(pool)
            close(pool)
            @test !isopen(pool)
            @test_throws ArgumentError approximate_many(pool, requests)
        end
        @test isempty(intersect(Set(ids), Set(Distributed.workers())))
        @test Set(Distributed.workers()) == previous_workers
        @test working_precision() == original
        @test_throws ArgumentError SollyaPool(0)
    end
else
    @testset "Independent local worker processes" begin
        @test_skip false # explicitly disabled by SOLLYA_TEST_WORKERS
    end
end
