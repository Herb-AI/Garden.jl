# # Divide-and-conquer program synthesis

# In this example, we ... TODO: continue description

using HerbGrammar
using HerbSearch: divide_and_conquer # TODO: be more specific, only import what required
using HerbBenchmarks.PBE_BV_Track_2018

# additional bitoperations for modified grammar
bvugt_cvc(n1::UInt, n2::UInt) = n1 > n2 ? UInt(1) : UInt(0) # returns whether n1 > n2
bveq1_cvc(n::UInt) = n == UInt(1) ? UInt(1) : UInt(0)

# Modification of grammar_PRE_100_10:
# - Conditions used for predicates
# - :Input used as start symbol for iterator (TODO: and constraint for predicates?)
# - :Bool used as start symbol for predicates iterator 
# - if-else statement to combine partial programs
# - additional bitoperations (TODO: why?)

grammar = @csgrammar begin
	Start = 0x0000000000000000
	Start = 0x0000000000000001
	Start = Input
	Input = _arg_1 # :Input added
	Start = Bool
	Bool = Condition # only introduced for constraint on predicates iterator
	Condition = bvugt_cvc(Start, Start) # n1 > n2
	Condition = bveq1_cvc(Start) # n == 1
	Start = bvnot_cvc(Start)
	Start = smol_cvc(Start)
	Start = ehad_cvc(Start)
	Start = arba_cvc(Start)
	Start = shesh_cvc(Start)
	Start = bvand_cvc(Start, Start)
	Start = bvor_cvc(Start, Start)
	Start = bvxor_cvc(Start, Start)
	Start = bvadd_cvc(Start, Start)
	Start = im_cvc(Start, Start, Start) # TODO: description
	Start = Bool ? Start : Start # if-else 
end

# grammar = grammar_PRE_100_10

# load problem
problem = problem_PRE_100_10

# define parameters
n_predicates = 50
sym_bool = :Bool
sym_start = :Start
sym_constraint = :Input
max_enumerations = 10

iterator = BFSIterator(grammar, :Start)
idx_ifelse = findfirst(r -> r == :($sym_bool ? $sym_start : $sym_start), grammar.rules)

# run divide-and-conquer program synthesis
final_program = divide_and_conquer(
	problem,
	iterator,
	sym_bool,
	sym_start,
	sym_constraint,
	n_predicates,
	max_enumerations,
)

# transform final program to Julia expression
expr = rulenode2expr(final_program, grammar)
println("-------------------------------------------")
println("| Julia expression of synthesised program |")
println("------------------------------------------")
println()
println(expr)
