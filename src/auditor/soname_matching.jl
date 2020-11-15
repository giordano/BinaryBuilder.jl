# Not everything has an SONAME
get_soname(oh::ObjectHandle) = nothing

# Auto-open a path into an ObjectHandle
function get_soname(path::AbstractString)
    try
        readmeta(get_soname, path)
    catch e
        @warn "Could not probe $(path) for an SONAME!" exception=(e, catch_backtrace())
        return nothing
    end
end

function get_soname(oh::ELFHandle)
    # Get the dynamic entries, see if it contains a DT_SONAME
    es = ELFDynEntries(oh)
    soname_idx = findfirst(e -> e.entry.d_tag == ELF.DT_SONAME, es)
    if soname_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Look up the SONAME from the string table
    return strtab_lookup(es[soname_idx])
end

function get_soname(oh::MachOHandle)
    # Get the dynamic entries, see if it contains an ID_DYLIB_CMD
    lcs = MachOLoadCmds(oh)
    id_idx = findfirst(lc -> typeof(lc) <: MachOIdDylibCmd, lcs)
    if id_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Return the Dylib ID
    return dylib_name(lcs[id_idx])
end


function ensure_soname(prefix::Prefix, path::AbstractString, platform::AbstractPlatform, logger;
                       verbose::Bool = false, autofix::Bool = false)
    # Skip any kind of Windows platforms
    if Sys.iswindows(platform)
        return AuditCheck(true, logger)
    end

    # Skip if this file already contains an SONAME
    rel_path = relpath(realpath(path), realpath(prefix.path))
    with_logger(logger) do
        soname = get_soname(path)
    end
    if soname != nothing
        if verbose
            with_logger(logger) do
                @info("$(rel_path) already has SONAME \"$(soname)\"")
            end
        end
        return AuditCheck(true, logger)
    else
        soname = basename(path)
    end

    # If we're not allowed to fix it, fail out
    if !autofix
        return AuditCheck(false, logger)
    end

    # Otherwise, set the SONAME
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    set_soname_cmd = ``
    
    if Sys.isapple(platform)
        install_name_tool = "/opt/bin/install_name_tool"
        set_soname_cmd = `$install_name_tool -id $(soname) $(rel_path)`
    elseif Sys.islinux(platform) || Sys.isbsd(platform)
        patchelf = "/usr/bin/patchelf"
        set_soname_cmd = `$patchelf $(patchelf_flags(platform)) --set-soname $(soname) $(rel_path)`
    end

    # Create a new linkage that looks like @rpath/$lib on OSX, 
    retval = with_logfile(prefix, "set_soname_$(basename(rel_path))_$(soname).log") do io
        run(ur, set_soname_cmd, io; verbose=verbose)
    end

    if !retval
        with_logger(logger) do
            @warn("Unable to set SONAME on $(rel_path)")
        end
        return AuditCheck(false, logger)
    end

    # Read the SONAME back in and ensure it's set properly
    with_logger(logger) do
        new_soname = get_soname(path)
    end
    if new_soname != soname
        with_logger(logger) do
            @warn("Set SONAME on $(rel_path) to $(soname), but read back $(string(new_soname))!")
        end
        return AuditCheck(false, logger)
    end

    if verbose
        with_logger(logger) do
            @info("Set SONAME of $(rel_path) to \"$(soname)\"")
        end
    end

    return AuditCheck(true, logger)
end

"""
    symlink_soname_lib(path::AbstractString)

We require that all shared libraries are accessible on disk through their
SONAME (if it exists).  While this is almost always true in practice, it
doesn't hurt to make doubly sure.
"""
function symlink_soname_lib(path::AbstractString, logger;
                            verbose::Bool = false,
                            autofix::Bool = false)
    # If this library doesn't have an SONAME, then just quit out immediately
    with_logger(logger) do
        soname = get_soname(path)
    end
    if soname === nothing
        return AuditCheck(true, logger)
    end

    # Absolute path to where the SONAME-named file should be
    soname_path = joinpath(dirname(path), basename(soname))
    if !isfile(soname_path)
        if autofix
            target = basename(path)
            if verbose
                with_logger(logger) do
                    @info("Library $(soname) does not exist, creating link to $(target)...")
                end
            end
            symlink(target, soname_path)
        else
            if verbose
                with_logger(logger) do
                    @info("Library $(soname) does not exist, failing out...")
                end
            end
            return AuditCheck(false, logger)
        end
    end
    return AuditCheck(true, logger)
end
