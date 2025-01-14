module IOCapture
using Logging

"""
    IOCapture.capture(f; rethrow=Any, color=false)

Runs the function `f` and captures the `stdout` and `stderr` outputs without printing them
in the terminal. Returns an object with the following fields:

* `.value :: Any`: return value of the function, or the error exception object on error
* `.output :: String`: captured `stdout` and `stderr`
* `.error :: Bool`: set to `true` if `f` threw an error, `false` otherwise
* `.backtrace :: Vector`: array with the backtrace of the error if an error was thrown

The behaviour can be customized with the following keyword arguments:

* `rethrow`:

  When set to `Any` (default), `capture` will rethrow any exceptions thrown
  by evaluating `f`.

  To only throw on a subset of possible exceptions pass the exception type
  instead, such as `InterruptException`. If multiple exception types may need
  to be thrown then pass a `Union{...}` of the types. Setting it to `Union{}`
  will capture all thrown exceptions. Captured exceptions will be returned via
  the `.value` field, and will also set `.error` and `.backtrace` accordingly.

* `color`: if set to `true`, `capture` inherits the `:color` property of `stdout` and
  `stderr`, which specifies whether ANSI color/escape codes are expected. This argument is
  only effective on Julia v1.6 and later.

# Extended help

`capture` works by temporarily redirecting the standard output and error streams
(`stdout` and `stderr`) using `redirect_stdout` and `redirect_stderr` to a temporary
buffer, evaluate the function `f` and then restores the streams. Both the captured text
output and the returned object get captured and returned:

```jldoctest
julia> c = IOCapture.capture() do
           println("test")
       end;

julia> c.output
"test\\n"
```

This approach does have some limitations -- see the README for more information.

**Exceptions.** Normally, if `f` throws an exception, `capture` simply re-throws it with
`rethrow`. However, by setting `rethrow` to `false`, it is also possible to capture
errors, which then get returned via the `.value` field. Additionally, `.error` is set to
`true`, to indicate that the function did not run normally, and the `catch_backtrace` of the
exception is returned via `.backtrace`.

As mentioned above, it is also possible to set `rethrow` to `InterruptException`. This will
make `capture` rethrow only `InterruptException`s. This is useful when you want to capture
all the exceptions, but allow the user to interrupt the running code with `Ctrl+C`.

**Recommended pattern.** The recommended way to refer to `capture` is by fully qualifying
the function name with `IOCapture.capture`. This is also why the package does not export
the function. However, if a shorter name is desired, we recommend renaming the function
when importing:

```julia
using IOcapture: capture as iocapture
```

This avoids the function name being too generic.
"""
function capture(f; rethrow::Type=Any, color::Bool=false)
    # Original implementation from Documenter.jl (MIT license)
    # Save the default output streams.
    default_stdout = stdout
    default_stderr = stderr

    # Redirect both the `stdout` and `stderr` streams to a single `Pipe` object.
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    @static if VERSION >= v"1.6.0-DEV.481" # https://github.com/JuliaLang/julia/pull/36688
        pe_stdout = IOContext(pipe.in, :color => get(stdout, :color, false) & color)
        pe_stderr = IOContext(pipe.in, :color => get(stderr, :color, false) & color)
    else
        pe_stdout = pipe.in
        pe_stderr = pipe.in
    end
    redirect_stdout(pe_stdout)
    redirect_stderr(pe_stderr)
    # Also redirect logging stream to the same pipe
    logger = ConsoleLogger(pe_stderr)

    # Bytes written to the `pipe` are captured in `output` and eventually converted to a
    # `String`. We need to use an asynchronous task to continously tranfer bytes from the
    # pipe to `output` in order to avoid the buffer filling up and stalling write() calls in
    # user code.
    output = IOBuffer()
    buffer_redirect_task = @async while !eof(pipe)
        write(output, readavailable(pipe))
    end

    # Run the function `f`, capturing all output that it might have generated.
    # Success signals whether the function `f` did or did not throw an exception.
    result, success, backtrace = with_logger(logger) do
        try
            f(), true, Vector{Ptr{Cvoid}}()
        catch err
            err isa rethrow && Base.rethrow(err)
            # If we're capturing the error, we return the error object as the value.
            err, false, catch_backtrace()
        finally
            # Force at least a single write to `pipe`, otherwise `readavailable` blocks.
            println()
            # Restore the original output streams.
            redirect_stdout(default_stdout)
            redirect_stderr(default_stderr)
            close(pipe)
            wait(buffer_redirect_task)
        end
    end
    (
        value = result,
        output = chomp(String(take!(output))),
        error = !success,
        backtrace = backtrace,
    )
end

end
