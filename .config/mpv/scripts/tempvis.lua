local current = false
local function on_visibility_change (name, value)
    if current == false then
        mp.set_property("sub-visibility", "yes")
        current = true
    else
        mp.set_property("sub-visibility", "no")
        current = false 
        mp.unobserve_property(on_visibility_change)
    end
end
local function callf ()
    mp.observe_property("sub-text", 'string', on_visibility_change)
end

mp.add_key_binding("s", "sub-corner", callf)
