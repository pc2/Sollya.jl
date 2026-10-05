# Adapted case inputs and expected results from Sollya 8.0. See NOTICE.md and COPYING.
@testset "Sollya 8.0 regression cases" begin
    with_session(Session(; precision=20)) do
        with_objects() do keep
            # tests-lib/tget_constant_as_mpq.c: exact conversion at low precision.
            expected = (
                "3.25" => big(13)//4,
                "76293.9453125" => big(9765625)//128,
                "1+1b-400+1b-53" => ((big(1)<<400)+(big(1)<<347)+1)//(big(1)<<400),
                "1-1b-54" => ((big(1)<<54)-1)//(big(1)<<54),
                "6/10" => big(3)//5,
                "-1b2000" => -(big(1)<<2000)//1,
            )
            for (text, value) in expected
                @test exact_rational(keep(sollya(text))) == value
            end
        end
    end
    with_session(Session(; precision=165)) do
        with_objects() do keep
            # tests-lib/tcoeff.c: coefficients from factored/summed polynomials.
            p = keep(sollya("1+x+x^2"))
            q = keep(sollya("(5*x+7)*x+9"))
            @test coefficients(p) == [1,1,1]
            @test coefficients(q) == [9,7,5]
            @test coefficients(keep(p+q)) == [10,8,6]

            # tests-lib/tfpminimax.c: integer fixed widths and constrained basis.
            narrow = keep(interval(-1//32,1//32))
            fixed = keep(fpminimax(keep(sollya("sin(x)")), 6, fill(32,7), narrow; arithmetic=:fixed))
            expected_fixed = keep(sollya("x*(1+x^2*(-357913941*2^-31+x^2*(35789873*2^-32)))"))
            @test equal(keep(expand(fixed)), keep(expand(expected_fixed)))
            @test all(c -> denominator(c*(big(1)<<32)) == 1, coefficients(fixed))

            d = keep(interval(-1//256,1//246))
            constrained = keep(sollya("1+x+x^2/2"))
            result = keep(fpminimax(keep(sollya("exp(x)")), [3,4], [:double,24], d;
                                   error=:relative, constrained))
            expected_exp = keep(sollya("1+x*(1+x*(1*2^-1+x*(375300225001191*2^-51+x*(5592621*2^-27))))"))
            @test equal(keep(expand(result)), keep(expand(expected_exp)))

            # Same upstream test's optional final minimax seed, with DD formats.
            cosf = keep(sollya("cos(x)"))
            seed = keep(remez(cosf,6,narrow))
            seeded = keep(fpminimax(cosf,6,[:double_double,:double_double,fill(:double,5)...],
                                   narrow; minimax=seed, error=:relative))
            @test degree(seeded) == 6
            @test bounds(keep(supnorm(seeded,cosf,narrow; error=:relative)))[2] < big(1)//(big(1)<<60)

            # doc/supnorm.tex: relative error across a removable zero of expm1.
            p = keep(sollya("x*(1+x*(2097145*2^-22+x*(349527*2^-21+x*(87609*2^-21+x*4369*2^-19))))"))
            f = keep(sollya("expm1(x)"))
            I = keep(interval(-1//4,1//4))
            certificate = keep(supnorm(p,f,I; error=:relative, accuracy=big(1)//(big(1)<<40)))
            lo,hi = bounds(certificate)
            @test 9//100000000 < lo <= hi < 1//10000000

            # tests-lib/tcheckinfnorm.c: false means failure to prove, not refutation.
            sinf = keep(sollya("sin(x)"))
            @test checkinfnorm(sinf,keep(interval(0,7//4)),1)
            @test !checkinfnorm(sinf,keep(interval(0,7//4)),1//2)
            @test checkinfnorm(sinf,keep(interval(0,20//39)),1//2)
        end
    end
end
