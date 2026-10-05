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
