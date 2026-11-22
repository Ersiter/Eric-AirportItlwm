#ifndef ItlCountryBootArg_hpp
#define ItlCountryBootArg_hpp

#include <pexpert/pexpert.h>

inline bool itlReadCountryOverride(char (&country)[3])
{
    char arg[4] = {};
    if (!PE_parse_boot_argn("itlwm_cc", arg, sizeof(arg)) || arg[2] ||
        arg[0] < 'A' || arg[0] > 'Z' || arg[1] < 'A' || arg[1] > 'Z' ||
        (arg[0] == 'Z' && arg[1] == 'Z'))
        return false;
    country[0] = arg[0];
    country[1] = arg[1];
    country[2] = '\0';
    return true;
}

#endif
