import Base.show

export CustomParser, Quoted

abstract type AbstractToken{T} end
fieldtype(::AbstractToken{T}) where {T} = T
fieldtype(::Type{AbstractToken{T}}) where {T} = T
fieldtype(::Type{T}) where {T<:AbstractToken} = fieldtype(supertype(T))

"""
`tryparsenext{T}(tok::AbstractToken{T}, str, i, till, localopts)`

Parses the string `str` starting at position `i` and ending at or before position `till`. `localopts` is a [LocalOpts](@ref) object which contains contextual options for quoting and NA parsing. (see [LocalOpts](@ref) documentation)

`tryparsenext` returns a tuple `(result, nextpos)` where `result` is of type `Union{Some{T}, Nothing}`, nothing if parsing failed, non-null containing the parsed value if it succeeded. If parsing succeeded, `nextpos` is the position the next token, if any, starts at. If parsing failed, `nextpos` is the position at which the parsing failed.
"""
function tryparsenext end

## options passed down for tokens (specifically NAToken, StringToken)
## inside a Quoted token
"""
    LocalOpts

Options local to the token currently being parsed.
- `endchar`: Till where to parse. (e.g. delimiter or quote ending character)
- `spacedelim`: Treat spaces as delimiters
- `quotechar`: the quote character
- `escapechar`: char that escapes the quote
- `includequotes`: whether to include quotes while parsing
- `includenewlines`: whether to include newlines while parsing
"""
struct LocalOpts
    endchar::Char         # End parsing at this char
    spacedelim::Bool
    quotechar::Char       # Quote char
    escapechar::Char      # Escape char
    includequotes::Bool   # Whether to include quotes in string parsing
    includenewlines::Bool # Whether to include newlines in string parsing
end

const default_opts = LocalOpts(',', false, '"', '"', false, false)
# helper function for easy testing:
@inline function tryparsenext(tok::AbstractToken, str, opts::LocalOpts=default_opts)
    tryparsenext(tok, str, firstindex(str), lastindex(str), opts)
end

# fallback for tryparsenext methods which don't care about local opts
@inline function tryparsenext(tok::AbstractToken, str, i, len, locopts)
    tryparsenext(tok, str, i, len)
end

struct WrapLocalOpts{T, X<:AbstractToken} <: AbstractToken{T}
    opts::LocalOpts
    inner::X
end

WrapLocalOpts(opts, inner) = WrapLocalOpts{fieldtype(inner), typeof(inner)}(opts, inner)

@inline function tryparsenext(tok::WrapLocalOpts, str, i, len, opts::LocalOpts=default_opts)
    tryparsenext(tok.inner, str, i, len, tok.opts)
end


# needed for promoting guessses
struct Unknown <: AbstractToken{Missing} end
fromtype(::Type{Missing}) = Unknown()
const nullableNA = Nullable{Missing}(missing)
function tryparsenext(::Unknown, str, i, len, opts)
    nullableNA, i
end
show(io::IO, ::Unknown) = print(io, "<unknown>")
struct CustomParser{T, F} <: AbstractToken{T}
    f::Function
end

"""
    CustomParser(f, T)

Provide a custom parsing mechanism.

# Arguments:

- `f`: the parser function
- `T`: The type of the parsed value

The parser function must take the following arguments:
- `str`: the entire string being parsed
- `pos`: the position in the string at which to start parsing
- `len`: the length of the string the maximum position where to parse till
- `opts`: a [LocalOpts](@ref) object with options local to the current field.

The parser function must return a tuple of two values:

- `result`: A `Union{Some{T}, Nothing}`. Set to nothing if parsing must fail, containing the value otherwise.
- `nextpos`: If parsing succeeded this must be the next position after parsing finished, if it failed this must be the position at which parsing failed.
"""
CustomParser(f, T) = CustomParser{T,typeof(f)}(f)

show(io::IO, c::CustomParser{T}) where {T} = print(io, "{{custom:$T}}")

@inline function tryparsenext(c::CustomParser, str, i, len, opts)
    c.f(str, i, len, opts)
end


# Numberic parsing
"""
parse numbers of type T
"""
struct Numeric{T} <: AbstractToken{T}
    decimal::Char
    thousands::Char
end
show(io::IO, c::Numeric{T}) where {T} = print(io, "<$T>")

Numeric(::Type{T}, decimal='.', thousands=',') where {T} = Numeric{T}(decimal, thousands)
fromtype(::Type{N}) where {N<:Number} = Numeric(N)

### Unsigned integers

function tryparsenext(::Numeric{T}, str, i, len) where {T<:Signed}
    R = Nullable{T}
    @chk2 sign, i = tryparsenext_sign(str, i, len)
    @chk2 x, i = tryparsenext_base10(T, str, i, len)

    @label done
    return R(convert(T, sign*x)), i

    @label error
    return R(), i
end

@inline function tryparsenext(::Numeric{T}, str, i, len) where {T<:Unsigned}
    tryparsenext_base10(T,str, i, len)
end

@inline _is_e(str, i) = str[i]=='e' || str[i]=='E'

@inline _is_negative(str, i) = str[i]=='-'

@inline _is_positive(str, i) = str[i]=='+'

@inline function convert_to_double(f1::Int64, exp::Int)
    f = Float64(f1)
    r = f1 - Int64(f) # get the remainder
    x = Double64(f) + Double64(r)
  
    maxexp = 308
    minexp = -256
  
    if exp >= 0
        x *= Double64(10.0)^(exp)
    else
        if exp < minexp # not sure why this is a good choice, but it seems to be!
            x /= Double64(10.0)^(-minexp)
            x /= Double64(10.0)^(-exp + minexp)
        else
            x /= Double64(10.0)^(-exp)
        end
    end
    return Float64(x)
end

@inline function tryparsenext(::Numeric{F}, str, i, len) where {F<:AbstractFloat}
    R = Nullable{F}

    y1 = iterate(str, i)
    y1===nothing && @goto error

    negate = false
    c = y1[1]
    if c=='-'
        negate = true
        i = y1[2]
    elseif c=='+'
        i = y1[2]
    end

    f1::Int64 = 0

    # read an integer up to the decimal point
    f1, rval1, idecpt = parse_uint_and_stop(str, i, len, f1)
    idecpt = read_digits(str, idecpt, len) # get any trailing digits
    i = idecpt

    ie = i
    frac_digits = 0

    # next thing must be dec pt.
    y2 = iterate(str, i)
    if y2!==nothing && y2[1]=='.'
        i =y2[2]
        f1, rval2, ie = parse_uint_and_stop(str, i, len, f1)
        # TODO This is incorrect for string types where a digit takes up
        # more than one codeunit, we need to return the number of digits
        # from parse_uint_and_stop instead. Ok for now because we are
        # not handling any such string types.
        frac_digits = ie - i

        ie = read_digits(str, ie, len) # get any trailing digits
    elseif !rval1 # no first number, and now no deciaml point => invalid
        @goto error
    end

    # Next thing must be exponent
    i = ie
    eval::Int32 = 0

    y3 = iterate(str, i)
    if y3!==nothing && _is_e(str, i)
        i = y3[2]
    
        y4 = iterate(str, i)
        if y4!==nothing
            enegate = false
            if _is_negative(str, i)
                enegate = true
                i = y4[2]
            elseif _is_positive(str, i)
                i = y4[2]
            end
        end
        eval, rval3, i = parse_uint_and_stop(str, i, len, eval)
        if enegate
            eval *= Int32(-1)
        end
    end

    exp = eval - frac_digits

    maxexp = 308
    minexp = -307

    if frac_digits <= 15 && -22 <= exp <= 22
        if exp >= 0
            f = F(f1)*10.0^exp
        else
            f = F(f1)/10.0^(-exp)
        end
    else
          f = convert_to_double(f1, exp)
    end

    if negate
        f = -f
    end

    @label done
    return R(convert(F, f)), i

    @label error
    return R(), i
end

struct Percentage <: AbstractToken{Float64}
end

const floatparser = Numeric(Float64)
function tryparsenext(::Percentage, str, i, len, opts)
    num, ii = tryparsenext(floatparser, str, i, len, opts)
    if isnull(num)
        return num, ii
    else
        # parse away the % char
        ii = eatwhitespaces(str, ii, len)
        y = iterate(str, ii)
        if y===nothing 
            return Nullable{Float64}(), ii # failed to parse %
        else
            c = y[1]; k = y[2]
            if c != '%'
                return Nullable{Float64}(), ii # failed to parse %
            else
                return Nullable{Float64}(num.value / 100.0), k # the point after %
            end
        end
    end
end

"""
Parses string to the AbstractString type `T`. If `T` is `StrRange` returns a
`StrRange` with start position (`offset`) and `length` of the substring.
It is used internally by `csvparse` for avoiding allocating strings.
"""
struct StringToken{T} <: AbstractToken{T}
end

function StringToken(t::Type{T}) where T
    StringToken{T}()
end
show(io::IO, c::StringToken) = print(io, "<string>")

fromtype(::Type{S}) where {S<:AbstractString} = StringToken(S)

function tryparsenext(s::StringToken{T}, str, i, len, opts) where {T}
    R = Nullable{T}
    p = ' '
    i0 = i
    if opts.includequotes
        y = iterate(str, i)
        if y!==nothing
            c = y[1]; ii = y[2]
            if c == opts.quotechar
                i = ii # advance counter so that
                       # the while loop doesn't react to opening quote
            end
        end
    end

    y2 = iterate(str, i)
    while y2!==nothing
        c = y2[1]; ii = y2[2]
        if opts.spacedelim && (c == ' ' || c == '\t')
            break
        elseif !opts.spacedelim && c == opts.endchar
            if opts.endchar == opts.quotechar
                # this means we're inside a quoted string
                if opts.quotechar == opts.escapechar
                    # sometimes the quotechar is the escapechar
                    # in that case we need to see the next char
                    y3 = iterate(str, ii)
                    if y3===nothing
                        if opts.includequotes
                            i=ii
                        end
                        break
                    else
                        nxt = y3[1]; j = y3[2]
                        if nxt == opts.quotechar
                            # the current character is escaping the
                            # next one
                            i = j # skip next char as well
                            p = nxt
                            y2 = iterate(str, i)
                            continue
                        end
                    end
                elseif p == opts.escapechar
                    # previous char escaped this one
                    i = ii
                    p = c
                    y2 = iterate(str, i)
                    continue
                end
            end
            if opts.includequotes
                i = ii
            end
            break
        elseif (!opts.includenewlines && isnewline(c))
            break
        end
        i = ii
        p = c

        y2 = iterate(str, i)
    end

    return R(_substring(T, str, i0, i-1)), i
end

@inline function _substring(::Type{String}, str, i, j)
    String(str[i:j])
end

@inline function _substring(::Type{T}, str, i, j) where {T<:SubString}
    T(str, i, j)
end

fromtype(::Type{StrRange}) = StringToken(StrRange)

@inline function alloc_string(str, r::StrRange)
    unsafe_string(pointer(str, 1 + r.offset), r.length)
end

@inline function _substring(::Type{StrRange}, str, i, j)
    StrRange(i - 1, j - i + 1)
end

@inline function _substring(::Type{<:WeakRefString}, str, i, j)
    WeakRefString(convert(Ptr{UInt8}, pointer(str, i)), j - i + 1)
end

export Quoted

struct Quoted{T, S<:AbstractToken} <: AbstractToken{T}
    inner::S
    required::Bool
    stripwhitespaces::Bool
    includequotes::Bool
    includenewlines::Bool
    quotechar::Union{Char, Nothing}
    escapechar::Union{Char, Nothing}
end

function show(io::IO, q::Quoted)
    c = quotechar(q, default_opts)
    print(io, "$c")
    show(io, q.inner)
    print(io, "$c")
end

"""
`Quoted(inner::AbstractToken; <kwargs>...)`

# Arguments:
- `inner`: The token inside quotes to parse
- `required`: are quotes required for parsing to succeed? defaults to `false`
- `includequotes`: include the quotes in the output. Defaults to `false`
- `includenewlines`: include newlines that appear within quotes. Defaults to `true`
- `quotechar`: character to use to quote (default decided by `LocalOpts`)
- `escapechar`: character that escapes the quote char (default set by `LocalOpts`)
"""
function Quoted(inner::S;
    required=false,
    stripwhitespaces=fieldtype(S)<:Number,
    includequotes=false,
    includenewlines=true,
    quotechar=nothing,   # This is to allow file-wide config
    escapechar=nothing) where S<:AbstractToken

    T = fieldtype(S)
    Quoted{T,S}(inner, required, stripwhitespaces, includequotes,
                includenewlines, quotechar, escapechar)
end

@inline quotechar(q::Quoted, opts) = q.quotechar === nothing ? opts.quotechar : q.quotechar
@inline escapechar(q::Quoted, opts) = q.escapechar === nothing ? opts.escapechar : q.escapechar

Quoted(t::Type; kwargs...) = Quoted(fromtype(t); kwargs...)

function tryparsenext(q::Quoted{T}, str, i, len, opts) where {T}
    y1 = iterate(str, i)
    if y1===nothing
        q.required && @goto error
        # check to see if inner thing is ok with an empty field
        @chk2 x, i = tryparsenext(q.inner, str, i, len, opts) error
        @goto done
    end
    c = y1[1]; ii = y1[2]
    quotestarted = false
    if quotechar(q, opts) == c
        quotestarted = true
        if !q.includequotes
            i = ii
        end

        if q.stripwhitespaces
            i = eatwhitespaces(str, i, len)
        end
    else
        q.required && @goto error
    end

    if quotestarted
        qopts = LocalOpts(quotechar(q, opts), false, quotechar(q, opts), escapechar(q, opts),
                         q.includequotes, q.includenewlines)
        @chk2 x, i = tryparsenext(q.inner, str, i, len, qopts)
    else
        @chk2 x, i = tryparsenext(q.inner, str, i, len, opts)
    end

    if i > len
        if quotestarted && !q.includequotes
            @goto error
        end
        @goto done
    end

    if q.stripwhitespaces
        i = eatwhitespaces(str, i, len)
    end
    y2 = iterate(str, i)
    y2===nothing && error("Internal error.")
    c = y2[1]; ii = y2[2]

    if quotestarted && !q.includequotes
        c != quotechar(q, opts) && @goto error
        i = ii
    end


    @label done
    return Nullable{T}(x), i

    @label error
    return Nullable{T}(), i
end

## Date and Time
struct DateTimeToken{T,S<:DateFormat} <: AbstractToken{T}
    format::S
end

"""
    DateTimeToken(T, fmt::DateFormat)

Parse a date time string of format `fmt` into type `T` which is
either `Date`, `Time` or `DateTime`.
"""
DateTimeToken(T::Type, df::S) where {S<:DateFormat} = DateTimeToken{T, S}(df)
DateTimeToken(df::S) where {S<:DateFormat} = DateTimeToken{DateTime, S}(df)
fromtype(df::DateFormat) = DateTimeToken(DateTime, df)
fromtype(::Type{DateTime}) = DateTimeToken(DateTime, ISODateTimeFormat)
fromtype(::Type{Date}) = DateTimeToken(Date, ISODateFormat)

function tryparsenext(dt::DateTimeToken{T}, str, i, len, opts) where {T}
    R = Nullable{T}
    nt, i = tryparsenext_internal(T, str, i, len, dt.format, opts.endchar)
    if isnull(nt)
        return R(), i
    else
        return R(T(nt.value...)), i
    end
end

### Missing

const nastrings_upcase = ["NA", "NULL", "N/A","#N/A", "#N/A N/A", "#NA",
                          "-1.#IND", "-1.#QNAN", "-NaN", "-nan",
                          "1.#IND", "1.#QNAN", "N/A", "NA", "NaN", "nan"]

const NA_STRINGS = sort!(vcat(nastrings_upcase, map(lowercase, nastrings_upcase)))

struct NAToken{T, S<:AbstractToken} <: AbstractToken{T}
    inner::S
    emptyisna::Bool
    endchar::Union{Char, Nothing}
    nastrings::Vector{String}
end

"""
`NAToken(inner::AbstractToken; options...)`

Parses a Nullable item.

# Arguments
- `inner`: the token to parse if non-null.
- `emptyisna`: should an empty item be considered NA? defaults to true
- `nastrings`: strings that are to be considered NA. Defaults to `$NA_STRINGS`
"""
function NAToken(
    inner::S,
  ; emptyisna=true
  , endchar=nothing
  , nastrings=NA_STRINGS) where S

    T = fieldtype(inner)
    NAToken{UnionMissing{T}, S}(inner, emptyisna, endchar, nastrings)
end

function show(io::IO, na::NAToken)
    show(io, na.inner)
    print(io, "?")
end

endchar(na::NAToken, opts) = na.endchar === nothing ? opts.endchar : na.endchar

function tryparsenext(na::NAToken{T}, str, i, len, opts) where {T}
    R = Nullable{T}
    i = eatwhitespaces(str, i, len)
    y1 = iterate(str,i)
    if y1===nothing
        if na.emptyisna
            @goto null
        else
            @goto error
        end
    end

    c = y1[1]; ii=y1[2]
    if (c == endchar(na, opts) || isnewline(c)) && na.emptyisna
       @goto null
    end

    if isa(na.inner, Unknown)
        @goto maybe_null
    end
    @chk2 x,ii = tryparsenext(na.inner, str, i, len, opts) maybe_null

    @label done
    return R(convert(T, x)), ii

    @label maybe_null
    naopts = LocalOpts(endchar(na,opts), opts.spacedelim, opts.quotechar,
                       opts.escapechar, false, opts.includenewlines)
    @chk2 nastr, ii = tryparsenext(StringToken(WeakRefString{UInt8}), str, i, len, naopts)
    if !isempty(searchsorted(na.nastrings, nastr))
        i=ii
        i = eatwhitespaces(str, i, len)
        @goto null
    end
    return R(), i

    @label null
    return R(missing), i

    @label error
    return R(), i
end

fromtype(::Type{Union{Missing,T}}) where T = NAToken(fromtype(T))

### Field parsing

abstract type AbstractField{T} <: AbstractToken{T} end # A rocord is a collection of abstract fields

struct Field{T,S<:AbstractToken} <: AbstractField{T}
    inner::S
    ignore_init_whitespace::Bool
    ignore_end_whitespace::Bool
    eoldelim::Bool
end

function Field(inner::S; ignore_init_whitespace=true, ignore_end_whitespace=true, eoldelim=false) where S
    T = fieldtype(inner)
    Field{T,S}(inner, ignore_init_whitespace, ignore_end_whitespace, eoldelim)
end

function Field(f::Field; inner=f.inner, ignore_init_whitespace=f.ignore_init_whitespace,
                  ignore_end_whitespace=f.ignore_end_whitespace,
                  eoldelim=f.eoldelim)
    T = fieldtype(inner)
    Field{T,typeof(inner)}(inner, ignore_init_whitespace,
                           ignore_end_whitespace, eoldelim)
end

function swapinner(f::Field, inner::AbstractToken;
        ignore_init_whitespace= f.ignore_end_whitespace
      , ignore_end_whitespace=f.ignore_end_whitespace
      , eoldelim=f.eoldelim
  )
    Field(inner;
        ignore_init_whitespace=ignore_end_whitespace
      , ignore_end_whitespace=ignore_end_whitespace
      , eoldelim=eoldelim
     )

end

function tryparsenext(f::Field{T}, str, i, len, opts) where {T}
    R = Nullable{T}
    i > len && @goto error
    if f.ignore_init_whitespace
        y1 = iterate(str, i)
        while y1!==nothing
            c = y1[1]; ii = y1[2]
            !isspace(c) && break
            i = ii
            y1 = iterate(str, i)
        end
    end
    @chk2 res, i = tryparsenext(f.inner, str, i, len, opts)

    if f.ignore_end_whitespace
        i0 = i
        y2 = iterate(str, i)
        while y2!==nothing
            c = y2[1]; ii = y2[2]
            !opts.spacedelim && opts.endchar == '\t' && c == '\t' && (i =ii; @goto done)
            !isspace(c) && c != '\t' && break
            i = ii
            y2 = iterate(str, i)
        end

        opts.spacedelim && i > i0 && @goto done
    end
    # todo don't ignore whitespace AND spacedelim

    if i > len
        if f.eoldelim
            @goto done
        else
            @goto error
        end
    end

    y3 = iterate(str, i)
    y3===nothing && error("Internal error.")
    c = y3[1]; ii = y3[2]
    opts.spacedelim && (isspace(c) || c == '\t') && (i=ii; @goto done)
    !opts.spacedelim && opts.endchar == c && (i=ii; @goto done)

    if f.eoldelim
        if c == '\r'
            i=ii
            y4 = iterate(str, i)
            if y4!==nothing
                c = y4[1]; ii = y4[2]
                if c == '\n'
                    i=ii
                end
            end
            @goto done
        elseif c == '\n'
            i=ii
            y5 = iterate(str, i)
            if y5!==nothing
                c = y5[1]; ii = y5[2]
                if c == '\r'
                    i=ii
                end
            end
            @goto done
        end
    end

    @label error
    return R(), i

    @label done
    return R(convert(T, res)), i
end

