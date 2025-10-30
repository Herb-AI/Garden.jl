##### This is an implementation of Aulile by Alperen Guncan and Ivo Yordanov, implemeted as a part of RIIDM 2025. 

`module.jl` contains the main Aulile loop, as well as modified *synthesizer* and *evaluator* that keep track of auxiliary scores and are extended with an aux, an interpreter, and a "new rule symbol". This is the symbol on the lhs of newly added rules by Aulile - it is different for each benchmark, hence parameterized. Also contains all required structs, as well as an implementation of a default aux function (ties score to number of correct programs, mirroring default synthesis), and a default interpreter (turn to Julia expr and evaluate).
            Exports `synth_with_aux`,    `evaluate_with_aux`,    `aulile`,    `construct_aux_function`


`aulile_auxiliary_functions.jl` contains two auxiliary functoins to compute levenstein distance as discribed in the Aulile paper. 
<!-- We list them in detail in the paper, but in essence it's mostly variations of edit distances. Also has a map between benchmark names and implemented aux functions, and a constructor helper. 

Benchmark is not imported, I decided to put components dependent on in in the garden.
-->

`test_aulile.jl` contains tests using strings grammar, running simple examples, including example form Aulile paper with our implementation. 