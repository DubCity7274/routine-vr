-- Meta Quest Touch / Touch Plus (Quest 2, 3, 3S, Pro).
-- The default layout, and the one other layouts are written against.
--
-- Mirrors an Xbox pad held "split": right face buttons A/B, left face
-- buttons X/Y, grips are bumpers, triggers are triggers. Sticks, START,
-- BACK and the d-pad stay owned by UEVR (snap turn, d-pad shifting,
-- menu combos), see input.lua.

return {
    name = "Meta Quest Touch (Quest 2/3/3S/Pro)",

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


    -- Touch controllers' aim pose already points along the barrel of a held object.
    uevr = {
        VR_ControllerPitchOffset = "0.000000",
    },

    hand_offset = { rot = { 0, 0, 0 }, loc = { 0, 0, 0 } },
}
