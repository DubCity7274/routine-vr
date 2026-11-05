-- Pico 4 / Pico 4 Ultra / Neo 3. Touch-style button set.

return {
    name = "Pico 4 / Neo 3",

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
        VR_ControllerPitchOffset = "0.000000",
    },

    hand_offset = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
}
