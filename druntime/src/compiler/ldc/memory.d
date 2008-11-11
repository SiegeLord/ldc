/**
 * This module exposes functionality for inspecting and manipulating memory.
 *
 * Copyright: Copyright (C) 2005-2006 Digital Mars, www.digitalmars.com.
 *            All rights reserved.
 * License:
 *  This software is provided 'as-is', without any express or implied
 *  warranty. In no event will the authors be held liable for any damages
 *  arising from the use of this software.
 *
 *  Permission is granted to anyone to use this software for any purpose,
 *  including commercial applications, and to alter it and redistribute it
 *  freely, in both source and binary form, subject to the following
 *  restrictions:
 *
 *  o  The origin of this software must not be misrepresented; you must not
 *     claim that you wrote the original software. If you use this software
 *     in a product, an acknowledgment in the product documentation would be
 *     appreciated but is not required.
 *  o  Altered source versions must be plainly marked as such, and must not
 *     be misrepresented as being the original software.
 *  o  This notice may not be removed or altered from any source
 *     distribution.
 * Authors:   Walter Bright, Sean Kelly
 */
module memory;

version = GC_Use_Dynamic_Ranges;

// does Posix suffice?
version(Posix)
{
    version = GC_Use_Data_Proc_Maps;
}

version(GC_Use_Data_Proc_Maps)
{
    version(Posix) {} else {
        static assert(false, "Proc Maps only supported on Posix systems");
    }

    version( D_Version2 )
    {
    private import stdc.posix.unistd;
    private import stdc.posix.fcntl;
    private import stdc.string;
    }
    else
    {
    private import tango.stdc.posix.unistd;
    private import tango.stdc.posix.fcntl;
    private import tango.stdc.string;
    }

    version = GC_Use_Dynamic_Ranges;
}

private
{
    version( linux )
    {
        //version = SimpleLibcStackEnd;

        version( SimpleLibcStackEnd )
        {
            extern (C) extern void* __libc_stack_end;
        }
        else
        {
            version( D_Version2 )
            import stdc.posix.dlfcn;
            else
            import tango.stdc.posix.dlfcn;
        }
    }
    version(LDC)
    {
        pragma(intrinsic, "llvm.frameaddress")
        {
                void* llvm_frameaddress(uint level=0);
        }
    }
}


/**
 *
 */
extern (C) void* rt_stackBottom()
{
    version( Win32 )
    {
        void* bottom;
        asm
        {
            mov EAX, FS:4;
            mov bottom, EAX;
        }
        return bottom;
    }
    else version( linux )
    {
        version( SimpleLibcStackEnd )
        {
            return __libc_stack_end;
        }
        else
        {
            // See discussion: http://autopackage.org/forums/viewtopic.php?t=22
                static void** libc_stack_end;

                if( libc_stack_end == libc_stack_end.init )
                {
                    void* handle = dlopen( null, RTLD_NOW );
                    libc_stack_end = cast(void**) dlsym( handle, "__libc_stack_end" );
                    dlclose( handle );
                }
                return *libc_stack_end;
        }
    }
    else version( darwin )
    {
        // darwin has a fixed stack bottom
        return cast(void*) 0xc0000000;
    }
    else
    {
        static assert( false, "Operating system not supported." );
    }
}


/**
 *
 */
extern (C) void* rt_stackTop()
{
    version(LDC)
    {
        return llvm_frameaddress();
    }
    else version( D_InlineAsm_X86 )
    {
        asm
        {
            naked;
            mov EAX, ESP;
            ret;
        }
    }
    else
    {
            static assert( false, "Architecture not supported." );
    }
}


private
{
    version( Win32 )
    {
        extern (C)
        {
            extern int _data_start__;
            extern int _bss_end__;

            alias _data_start__ Data_Start;
            alias _bss_end__    Data_End;
        }
    }
    else version( linux )
    {
        extern (C)
        {
            extern int _data;
            extern int __data_start;
            extern int _end;
            extern int _data_start__;
            extern int _data_end__;
            extern int _bss_start__;
            extern int _bss_end__;
            extern int __fini_array_end;
        }

            alias __data_start  Data_Start;
            alias _end          Data_End;
    }

    version( GC_Use_Dynamic_Ranges )
    {
        version( D_Version2 )
        private import stdc.stdlib;
        else
        private import tango.stdc.stdlib;

        struct DataSeg
        {
            void* beg;
            void* end;
        }

        DataSeg* allSegs = null;
        size_t   numSegs = 0;

        extern (C) void _d_gc_add_range( void* beg, void* end )
        {
            void* ptr = realloc( allSegs, (numSegs + 1) * DataSeg.sizeof );

            if( ptr ) // if realloc fails, we have problems
            {
                allSegs = cast(DataSeg*) ptr;
                allSegs[numSegs].beg = beg;
                allSegs[numSegs].end = end;
                numSegs++;
            }
        }

        extern (C) void _d_gc_remove_range( void* beg )
        {
            for( size_t pos = 0; pos < numSegs; ++pos )
            {
                if( beg == allSegs[pos].beg )
                {
                    while( ++pos < numSegs )
                    {
                        allSegs[pos-1] = allSegs[pos];
                    }
                    numSegs--;
                    return;
                }
            }
        }
    }

    alias void delegate( void*, void* ) scanFn;

    void* dataStart,  dataEnd;
}


/**
 *
 */
extern (C) void rt_scanStaticData( scanFn scan )
{
    scan( dataStart, dataEnd );

    version( GC_Use_Dynamic_Ranges )
    {
        for( size_t pos = 0; pos < numSegs; ++pos )
        {
            scan( allSegs[pos].beg, allSegs[pos].end );
        }
    }
}

void initStaticDataPtrs()
{
    version( D_Version2 )
    enum { int S = (void*).sizeof }
    else
    const int S = (void*).sizeof;

    // Can't assume the input addresses are word-aligned
    static void* adjust_up( void* p )
    {
        return p + ((S - (cast(size_t)p & (S-1))) & (S-1)); // cast ok even if 64-bit
    }

    static void * adjust_down( void* p )
    {
        return p - (cast(size_t) p & (S-1));
    }

    version( Win32 )
    {
        dataStart = adjust_up( &Data_Start );
        dataEnd   = adjust_down( &Data_End );
    }
    else version( GC_Use_Data_Proc_Maps )
    {
        // TODO: Exclude zero-mapped regions

        int   fd = open("/proc/self/maps", O_RDONLY);
        int   count; // %% need to configure ret for read..
        char  buf[2024];
        char* p;
        char* e;
        char* s;
        void* start;
        void* end;

        p = buf.ptr;
        if (fd != -1)
        {
            while ( (count = read(fd, p, buf.sizeof - (p - buf.ptr))) > 0 )
            {
                e = p + count;
                p = buf.ptr;
                while (true)
                {
                    s = p;
                    while (p < e && *p != '\n')
                        p++;
                    if (p < e)
                    {
                        // parse the entry in [s, p)
                        static if( S == 4 )
                        {
                            enum Ofs
                            {
                                Write_Prot = 19,
                                Start_Addr = 0,
                                End_Addr   = 9,
                                Addr_Len   = 8,
                            }
                        }
                        else static if( S == 8 )
                        {
                            enum Ofs
                            {
                                Write_Prot = 35,
                                Start_Addr = 0,
                                End_Addr   = 9,
                                Addr_Len   = 17,
                            }
                        }
                        else
                        {
                            static assert( false );
                        }

                        // %% this is wrong for 64-bit:
                        // uint   strtoul(char *,char **,int);

                        if( s[Ofs.Write_Prot] == 'w' )
                        {
                            s[Ofs.Start_Addr + Ofs.Addr_Len] = '\0';
                            s[Ofs.End_Addr + Ofs.Addr_Len] = '\0';
                            start = cast(void*) strtoul(s + Ofs.Start_Addr, null, 16);
                            end   = cast(void*) strtoul(s + Ofs.End_Addr, null, 16);

                            // 1. Exclude anything overlapping [dataStart, dataEnd)
                            // 2. Exclude stack
                            if ( ( !dataEnd ||
                                   !( dataStart >= start && dataEnd <= end ) ) &&
                                 !( &buf[0] >= start && &buf[0] < end ) )
                            {
                                // we already have static data from this region.  anything else
                                // is heap (%% check)
                                debug (ProcMaps) printf("Adding map range %p 0%p\n", start, end);
                                _d_gc_add_range(start, end);
                            }
                        }
                        p++;
                    }
                    else
                    {
                        count = p - s;
                        memmove(buf.ptr, s, count);
                        p = buf.ptr + count;
                        break;
                    }
                }
            }
            close(fd);
        }
    }
    else version(linux)
    {
        dataStart = adjust_up( &Data_Start );
        dataEnd   = adjust_down( &Data_End );
    }
    else
    {
        static assert( false, "Operating system not supported." );
    }
}