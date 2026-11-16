#ifndef ItlAWDLBootArg_hpp
#define ItlAWDLBootArg_hpp

#include <pexpert/pexpert.h>

/*
 * -itlawdl alone turns on everything AirDrop needs; the single flags that were once listed one by one in the
 * boot-args (-itlawdllisten, -itlawdltx, -itlawdldata, -itlawdlpromisc, -itlawdlp2p, -itlawdlaw, -itlawdlhunt,
 * -itlawdlbaaccept, -itlawdllistener, -itlawdlclient) still work for a test that wants one of them without
 * the rest.
 */
inline bool itlAWDLBootFlag(const char *single)
{
    int value = 0;
    return PE_parse_boot_argn("-itlawdl", &value, sizeof(value)) ||
        PE_parse_boot_argn(single, &value, sizeof(value));
}

#endif
