#ifndef DORIC_SYSTEM_WRAPPER_GLOBAL_H
#define DORIC_SYSTEM_WRAPPER_GLOBAL_H

#if defined(DORIC_SYSTEM_LIBRARY)
#  define DORIC_SYSTEM_WRAPPER_EXPORT __declspec(dllexport)
#else
#  define DORIC_SYSTEM_WRAPPER_EXPORT __declspec(dllimport)
#endif

#endif // DORIC_SYSTEM_WRAPPER_GLOBAL_H
