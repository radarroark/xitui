pub const Key = union(enum) {
    unknown,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    home,
    end,
    page_up,
    page_down,
    codepoint: u21,
};
