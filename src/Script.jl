function generate_script(p::AbstractPlatform)
    return preamble(p) *
        configure(p) *
        build(p) *
        install(p)
end
