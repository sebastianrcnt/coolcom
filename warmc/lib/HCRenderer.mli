(** Render the shared code generation IR as a standalone native Cool module.
    The optional entry describes (function, ExitCode type, RootCapability type).
    Without an entry, emit user functions and their reachable dependencies.
    Unsupported C embeds and Float32 produce a compiler diagnostic. *)
val render : CRepr.c_unit list -> (string * string * string option) option -> string
