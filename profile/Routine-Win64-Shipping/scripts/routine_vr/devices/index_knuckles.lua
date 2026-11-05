-- Valve Index "Knuckles" controllers. Same button set as Touch (A/B on both
-- hands, stick, grip), so the layout matches; the grip angle is steeper.

return {
    name = "Valve Index (Knuckles)",

    buttons = {
        A  = { "a_r" },
        B  = { "b_r" },
        X  = { "a_l" },
        Y  = { "b_l" },
        LB = { "grip_l" },
        RB = { "grip_r" },
        LS = { "stick_click_l" },
        RS = { "stick_click_r" },
    },

    triggers = {
        LT = { "trigger_l" },
        RT = { "trigger_r" },
    },


    uevr = {
        VR_ControllerPitchOffset = "-15.000000",
    },

    hand_offset = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
}
