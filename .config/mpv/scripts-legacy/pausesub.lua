function on_pause_change(name, value)
    if value == true then
        mp.set_property("sub-visibility", "yes")
    else
        mp.set_property("sub-visibility", "no")
    end
end
mp.observe_property("pause", "bool", on_pause_change)
