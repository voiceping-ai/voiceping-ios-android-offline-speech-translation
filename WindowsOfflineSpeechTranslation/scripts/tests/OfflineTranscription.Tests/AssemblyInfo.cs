using System.Runtime.CompilerServices;

// Required for LibraryImport source generation in the included Interop/*.cs files.
// The native DLLs won't be loaded during tests — only managed code paths are tested.
[assembly: DisableRuntimeMarshalling]
