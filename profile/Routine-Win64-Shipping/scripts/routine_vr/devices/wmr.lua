-- Windows Mixed Reality / HP Reverb G2 (original WMR wands have no face buttons).
-- Face buttons come from clicking touchpad quadrants; the thumbstick still
-- drives movement through UEVR. Reverb G2 controllers expose A/B/X/Y too, so
-- those are listed as well and either works.

return {
    name = "Windows Mixed Reality",

    buttons = {
        A  = { "a_r", "pad_down_r" },
        B  = { "b_r", "pad_right_r" },
        X  = { "a_l", "pad_left_r" },
        Y  = { "b_l", "pad_up_r" },
        LB = { "grip_l" },
        RB = { "grip_r" },
        LS = { "stick_click_l", "pad_down_l" },
        RS = { "stick_click_r" },
    },

    triggers = {
        LT = { "trigger_l" },
        RT = { "trigger_r" },
    },


    uevr = {
        VR_ControllerPitchOffset = "-10.000000",
    },

    hand_offset = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
}
