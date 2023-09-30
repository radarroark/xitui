pub const Key = union(enum) {
    unknown,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    codepoint: u21,
};
