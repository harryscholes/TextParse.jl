if isdefined(Base, :datatype_name)
    datatype_name(x) = Base.datatype_name(x)
else
    datatype_name(t) = t.name.name
end

const Str = String
import Base.Dates: CONVERSION_SPECIFIERS, TimeType, DatePart, tryparsenext, character_codes, genvar, CONVERSION_TRANSLATIONS, CONVERSION_DEFAULTS, _directives, DateLocale
include("date-tryparse-internal.jl")
const ISODateFormat = Base.Dates.ISODateFormat
const ISODateTimeFormat = Base.Dates.ISODateTimeFormat
const RFC1123Format = Base.Dates.RFC1123Format

