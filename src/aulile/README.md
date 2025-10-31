##### Implementation of Aulile

`module.jl` contains the main Aulile loop, as well as modified *synthesizer* and *evaluator* that keep track of auxiliary scores and are extended with an aux, an interpreter, and a "new rule symbol". This is the symbol on the lhs of newly added rules by Aulile - it is different for each benchmark, hence parameterized. Also contains all required structs, as well as an implementation of a default aux function (ties score to number of correct programs, mirroring default synthesis), and a default interpreter (turn to Julia expr and evaluate).
            Exports `synth_with_aux`,    `evaluate_with_aux`,    `aulile`,    `construct_aux_function`


`test_aulile.jl` contains tests using strings grammar, running simple examples, including example form Aulile paper with our implementation. 