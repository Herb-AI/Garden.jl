##### Iplementation of Compression algorithm for library learning by Stef Rasing and Danila Bren, implemeted as a part of RIIDM 2025.

`method.jl` imports functoin `refactor_grammar` that does the compression given some example *programs* on the provided *grammar*. 
The function takes following arguments:
- `programs`
- `grammar`
- `k`, def=1
- `max_compression_tokens`, def=10
- `time_limit_sec`, def=60. 
- `ASP_PATH`, def="compression.lp"
The function uses Clingo to search for `k` subtress shared between provided `programs` that have up to `max_compression_tokens`. It terminates after after finding optimal results or the given time limit, in which case best compression found so far is used. 
`refactor grammar` returns a new grammar with compressed rules added to it, and a list of found compressions.

There are two ASP models to extract subtrees, `compression.lp`, that is used by default, and `compression_large_k.lp`. The latter is designed to work with bigger values of `k`, but performs worse for smaller values. 