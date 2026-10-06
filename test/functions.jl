@testset "Expressions, polynomials and interval evaluation" begin
    with_session() do
        with_objects() do keep
            x = keep(variable())
            p = keep(sollya("(5*x+7)*x+9"))
            @test coefficients(p) == [9, 7, 5]
            @test degree(p) == 2
            @test exact_rational(keep(coeff(p, 17))) == 0
            @test_throws ArgumentError coeff(p, -1)
            f = keep(exp(x))
            @test_throws SollyaError degree(f)
            @test_throws SollyaError coeff(f, 0)
            @test_throws SollyaError coefficients(keep(sollya("x + exp(1)")))
            @test coefficients(keep(SollyaObject(0))) == [0]
            @test equal(keep(differentiate(p)), keep(sollya("10*x+7")))
            for transform in (horner, canonical, expand, simplify)
                @test equal(keep(transform(p)), p)
            end
            @test equal(keep(substitute(p, keep(x + 1))), keep(sollya("5*x^2+17*x+21")))
            @test exact_rational(keep(evaluate(p, 2))) == 43
            @test equal(keep(-x), keep(0 - x))
            @test equal(keep((x + 1) / (x + 2)), keep(sollya("(x+1)/(x+2)")))
            @test equal(keep(2^x), keep(sollya("2^x")))
            @test equal(keep(x^2), keep(sollya("x*x")))
            for (fn, text) in (
                (sqrt, "sqrt"),
                (exp, "exp"),
                (log, "log"),
                (log2, "log2"),
                (log10, "log10"),
                (sin, "sin"),
                (cos, "cos"),
                (tan, "tan"),
                (asin, "asin"),
                (acos, "acos"),
                (atan, "atan"),
                (sinh, "sinh"),
                (cosh, "cosh"),
                (tanh, "tanh"),
                (asinh, "asinh"),
                (acosh, "acosh"),
                (atanh, "atanh"),
                (abs, "abs"),
                (erf, "erf"),
                (erfc, "erfc"),
                (log1p, "log1p"),
                (expm1, "expm1"),
                (ceil, "ceil"),
                (floor, "floor"),
            )
                @test equal(keep(fn(x)), keep(sollya("$text(x)")))
            end
            I = keep(interval(0, 1))
            @test bounds(I) == (0, 1)
            @test isrange(I)
            @test isfunction(f)
            @test !isrange(f)
            @test exact_rational(keep(midpoint(I))) == 1 // 2
            @test_throws ArgumentError interval(1, 0)
            J = keep(interval(1 // 10))
            lo, hi = bounds(J)
            @test lo <= 1 // 10 <= hi
            @test lo < hi
            @test bounds(keep(evaluate(p, I))) == (9, 21)
            @test bounds(keep(enclosure(p, 2))) == (43, 43)
            @test bounds(keep(enclosure(p, I))) == (9, 21)
            lo, hi = bounds(keep(enclosure(f, 1)))
            setprecision(BigFloat, 512) do
                @test BigFloat(lo) < exp(BigFloat(1)) < BigFloat(hi)
            end
            a = keep(sollya("1/10"))
            @test exact_rational(keep(round_to(a, :single; mode = :down))) < 1 // 10
            @test exact_rational(keep(round_to(a, :single; mode = :up))) > 1 // 10
            @test exact_rational(keep(round_to(a, :single))) ==
                  Rational{BigInt}(Float32(0.1))
            @test exact_rational(keep(round_to(a, 24; mode = :zero))) < 1 // 10
            @test_throws ArgumentError round_to(a, :unknown)
            @test_throws ArgumentError round_to(a, 1)
            @test_throws ArgumentError round_to(a, :single; mode = :unknown)
        end
    end
end

@testset "BigFloat bounds preserve interval enclosures" begin
    with_session(Session(; precision = 20)) do
        with_objects() do keep
            for (endpoints, expected) in (
                ((9 // 8, 11 // 8), (1, 3 // 2)),
                ((-11 // 8, -9 // 8), (-3 // 2, -1)),
                ((-9 // 8, 11 // 8), (-5 // 4, 3 // 2)),
                ((-3 // 4, 7 // 8), (-3 // 4, 7 // 8)),
                ((9 // 8, 9 // 8), (1, 5 // 4)),
                ((0, 0), (0, 0)),
            )
                domain = keep(interval(endpoints...))
                result = bounds(BigFloat, domain; precision = 3)
                @test result isa Tuple{BigFloat, BigFloat}
                @test result == expected
                @test precision.(result) == (3, 3)
                @test bounds(domain) == endpoints
            end
            for endpoints in (
                (1 // 10, 1 // 3),
                (-1 // 3, -1 // 10),
                (big(1) // (big(1) << 2000), big(1) // (big(1) << 1999)),
                ((big(1) << 2000) + 1, (big(1) << 2001) + 1),
            )
                domain = keep(interval(endpoints...))
                stored = bounds(domain)
                for bits in (1, 12, 256)
                    result = bounds(BigFloat, domain; precision = bits)
                    lo, hi = map(x -> exact_rational(keep(SollyaObject(x))), result)
                    @test lo <= stored[1] <= endpoints[1] <= endpoints[2] <= stored[2] <= hi
                    @test precision.(result) == (bits, bits)
                end
            end
            domain =
                keep(interval(1 - big(1) // (big(1) << 200), 1 + big(1) // (big(1) << 200)))
            setprecision(BigFloat, 64) do
                for mode in (RoundNearest, RoundDown, RoundUp, RoundToZero, RoundFromZero)
                    setrounding(BigFloat, mode) do
                        @test bounds(BigFloat, domain) ==
                              (prevfloat(BigFloat(1)), nextfloat(BigFloat(1)))
                        @test precision.(bounds(BigFloat, domain)) == (64, 64)
                        @test bounds(BigFloat, domain; precision = 3) == (7 // 8, 5 // 4)
                        @test precision(BigFloat) == 64
                        @test rounding(BigFloat) == mode
                        @test working_precision() == 20
                    end
                end
            end
            @test isopen(domain)
            @test_throws DomainError bounds(BigFloat, domain; precision = 0)
            for text in ("1", "x", "[|1,2|]")
                @test_throws ArgumentError bounds(BigFloat, keep(sollya(text)))
            end
            for text in ("[-infty;1]", "[0;infty]", "[-infty;infty]", "[NaN;NaN]")
                @test_throws SollyaError bounds(BigFloat, keep(sollya(text)))
            end
            close(domain)
            @test_throws ArgumentError bounds(BigFloat, domain)
        end
    end
end

@testset "Broadcasting expressions, intervals and native lists" begin
    with_objects() do keep
        x = keep(variable())
        values = BigFloat[1, 2]
        @test coefficients.(keep.(x .+ values)) == [[1, 1], [2, 1]]
        @test coefficients.(keep.(values .+ x)) == [[1, 1], [2, 1]]
        @test equal(keep(sin.(x)), keep(sin(x)))

        p = keep(x^2)
        @test exact_rational.(keep.(evaluate.(p, values))) == [1, 4]
        domain = keep(interval(0, 1))
        @test bounds.(keep.(evaluate.([x, p], domain))) == [(0, 1), (0, 1)]

        list = keep(sollya_list([1, 2]))
        @test exact_rational.(keep.(list .+ values)) == [2, 4]
        @test coefficients.(keep.(list .+ x)) == [[1, 1], [2, 1]]
        @test length.(Ref(list)) == 2
        empty = keep(sollya_list([]))
        @test isempty(empty .+ x)
    end
end

@testset "Minimax seeds preserve coefficient formats" begin
    with_session(Session(; precision = 128)) do
        with_objects() do keep
            f = keep(sollya("exp(x)"))
            domain = keep(interval(0, 1))
            seed = keep(remez(f, 3, domain))
            seed_coefficients = keep(sollya_list(coefficients(seed)))
            for constrained in (nothing, 0),
                (kind, minimax) in ((:polynomial, seed), (:list, seed_coefficients))

                @testset "constraint=$constrained, seed=$kind" begin
                    p = keep(fpminimax(f, 3, :single, domain; constrained, minimax))
                    @test degree(p) == 3
                    @test all(c -> Rational{BigInt}(Float32(c)) == c, coefficients(p))
                    certificate = keep(supnorm(p, f, domain))
                    @test bounds(certificate)[2] < 1 // 1000
                end
            end
        end
    end
end

@testset "Norm accuracy validation" begin
    with_session() do
        with_objects() do keep
            p = keep(SollyaObject(0))
            f = keep(SollyaObject(1))
            domain = keep(interval(0, 1))
            for accuracy in (-1, 0, 1, 2, NaN, -Inf, Inf, 1 // 0, BigFloat(NaN))
                @test_throws ArgumentError supnorm(p, f, domain; accuracy)
                @test_throws ArgumentError ApproximationRequest("1", (0, 1); accuracy)
            end
            for text in ("-1", "0", "1", "NaN", "infty", "x", "[0.1;0.2]")
                for accuracy in (text, keep(sollya(text)))
                    @test_throws ArgumentError supnorm(p, f, domain; accuracy)
                end
            end
            for accuracy in (1 // 1024, 0.5, BigFloat(0.5), prevfloat(1.0))
                lo, hi = bounds(keep(supnorm(p, f, domain; accuracy)))
                @test lo <= 1 <= hi
                @test hi / lo - 1 <= accuracy
                request = ApproximationRequest("1", (0, 1); accuracy)
                @test request.accuracy == Rational{BigInt}(accuracy)
            end
            for text in ("1/1024", "1/pi")
                accuracy = keep(sollya(text))
                lo, hi = bounds(keep(supnorm(p, f, domain; accuracy = text)))
                @test lo <= 1 <= hi
                lo, hi = bounds(keep(supnorm(p, f, domain; accuracy)))
                @test lo <= 1 <= hi
                @test isopen(accuracy)
            end
        end
    end
end

@testset "Approximation and proof contracts" begin
    with_session() do
        with_objects() do keep
            f = keep(sollya("erf(x)"))
            I = keep(interval(0, 1 // 4))
            p = keep(fpminimax(f, 5, :single, I))
            @test length(coefficients(p)) == 6
            certificate = keep(supnorm(p, f, I))
            lo, hi = bounds(certificate)
            @test 0 < lo <= hi < 1 // 100000000
            float_bounds = bounds(BigFloat, certificate; precision = 24)
            exported_lo, exported_hi =
                map(x -> exact_rational(keep(SollyaObject(x))), float_bounds)
            @test exported_lo <= lo <= hi <= exported_hi
            @test precision.(float_bounds) == (24, 24)
            # Check returned proof bounds against separate 512-bit evaluations;
            # the finite samples complement the native uniform certificate.
            cs = coefficients(p)
            setprecision(BigFloat, 512) do
                for k = 0:32
                    t = BigFloat(k) / 128
                    polynomial =
                        foldr((a, y) -> BigFloat(a) + t * y, cs; init = BigFloat(0))
                    # Independent reference: erf is checked via Sollya intervals
                    # below; exp is also checked against Julia MPFR later.
                    image = keep(enclosure(f, k // 128))
                    a, b = bounds(image)
                    @test BigFloat(a) - BigFloat(hi) <=
                          polynomial <=
                          BigFloat(b) + BigFloat(hi)
                end
            end
            difference = keep(p - f)
            @test checkinfnorm(difference, I, 1 // 100000000)
            estimate = keep(dirtyinfnorm(difference, I))
            @test 0 < Float64(estimate) <= Float64(hi) * 1.001
            @test_throws ArgumentError fpminimax(f, 5, [:single], I)
            @test_throws ArgumentError fpminimax(f, [2, 1], :single, I)
            @test_throws ArgumentError fpminimax(f, 5, :single, I; arithmetic = :fixed)
            @test_throws ArgumentError fpminimax(f, 5, :single, I; error = :unknown)
            @test_throws ArgumentError fpminimax(f, 5, :single, f)
            @test_throws SollyaError supnorm(f, f, I) # p must be a polynomial

            expf = keep(sollya("exp(x)"))
            wide = keep(interval(0, 1))
            minimax = keep(remez(expf, 5, wide; quality = 1 // 1000000))
            @test degree(minimax) == 5
            c = keep(supnorm(minimax, expf, wide))
            @test bounds(c)[2] < 1 // 800000
            cs = coefficients(minimax)
            setprecision(BigFloat, 512) do
                for k = 0:16
                    t = BigFloat(k) / 16
                    value = foldr((a, y) -> BigFloat(a) + t * y, cs; init = BigFloat(0))
                    @test abs(value - exp(t)) <= BigFloat(bounds(c)[2])
                end
            end
            norm = keep(infnorm(expf, wide))
            a, b = bounds(norm)
            setprecision(BigFloat, 512) do
                @test BigFloat(a) < exp(BigFloat(1)) < BigFloat(b)
            end
            @test bounds(keep(guessdegree(expf, wide, 1 // 1000000; maxdegree = 10))) ==
                  (6, 6)
            zeros = keep(findzeros(keep(sollya("x^2-1")), keep(interval(-2, 2))))
            @test length(zeros) == 2
            for (index, root) in enumerate((-1, 1))
                a, b = bounds(keep(zeros[index]))
                @test a <= root <= b
            end
            dirty = keep(dirtyfindzeros(keep(sollya("x^2-1")), keep(interval(-2, 2))))
            @test [exact_rational(keep(dirty[k])) for k = 1:length(dirty)] == [-1, 1]
        end
    end
end
