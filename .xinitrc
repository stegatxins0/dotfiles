# [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/x11/xprofile" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/x11/xprofile"
xrandr --setprovideroutputsource modesettings NVIDIA-0
xrandr --auto
exec bspwm

