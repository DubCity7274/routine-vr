-- HTC Vive wands. No face buttons and a touchpad instead of a stick:
-- right pad quadrants are the face buttons, left pad click sprints.
-- Movement comes from the left pad axis via UEVR.

return {
    name = "HTC Vive wands",

    buttons = {
        A  = { "pad_down_r" },
        B  = { "pad_right_r" },
        X  = { "pad_left_r" },
        Y  = { "pad_up_r" },
        LB = { "grip_l" },
        RB = { "grip_r" },
        LS = { "stick_click_l" },
        RS = { "pad_left_l", "pad_right_l" },
        START = { "system" },
    },

    triggers = {
        LT = { "trigger_l" },
        RT = { "trigger_r" },
    },


    uevr = {
        VR_ControllerPitchOffset = "-30.000000",
    },

    hand_offset = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
}
