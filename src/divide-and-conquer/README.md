# Divide-and-conquer program synthesis

Implementation of a basic divide-and-conquer program synthesis approach in Herb.jl. The synthesizer takes input-output examples as problem specification and produces a program that satisfies them.

## How it works

The synthesis process consists of three phases: 

1. **Divide**: Split the problem into subsets, where each subset corresponds to one input-output example.
1. **Decide**: Search for partial programs that solve individual subsets using breadth-first search (BFS). The search terminates when either:
   - All subsets have at least one solution
   - Maximum iterations reached
   - Time limit exceeded
1. **Conquer**: Combine partial solutions into a final program by learning a decision tree. The decision tree requires:
   - Features: Feature vectors are created by evaluating an input from the IO examples on predicates. The predicates are generated using a BFS iterator with `Bool` as start symbol.
   - Labels: Partial programs found in the decide phase
   The decision tree converted to a program using the features in combination with conditional statements.

## How to run

## References
