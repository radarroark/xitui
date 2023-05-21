const std = @import("std");
const main = @import("./main.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

test "end to end" {
    const temp_dir_name = "temp-test-end-to-end";

    const allocator = std.testing.allocator;
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    // start libgit
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // get the current working directory path.
    // we can't just call std.fs.cwd() all the time because we're
    // gonna change it later. and since defers run at the end,
    // if you call std.fs.cwd() in them you're gonna have a bad time.
    var cwd_path_buffer = [_]u8{0} ** std.fs.MAX_PATH_BYTES;
    const cwd_path = try std.fs.cwd().realpath(".", &cwd_path_buffer);
    var cwd = try std.fs.openDirAbsolute(cwd_path, .{});
    defer cwd.close();

    // create the temp dir
    var temp_dir = try cwd.makeOpenPath(temp_dir_name, .{});
    defer cwd.deleteTree(temp_dir_name) catch {};
    defer temp_dir.close();

    // create the repo dir
    var repo_dir = try temp_dir.makeOpenPath("repo", .{});
    defer repo_dir.close();

    // get repo path for libgit
    var repo_path_buffer = [_]u8{0} ** std.fs.MAX_PATH_BYTES;
    const repo_path = @ptrCast([*c]const u8, try repo_dir.realpath(".", &repo_path_buffer));

    // init repo
    var repo: ?*c.git_repository = null;
    try expectEqual(0, c.git_repository_init(&repo, repo_path, 0));
    defer c.git_repository_free(repo);

    // make sure the git dir was created
    var git_dir = try repo_dir.openDir(".git", .{});
    defer git_dir.close();

    // add and commit
    {
        // make file
        var hello_txt = try repo_dir.createFile("hello.txt", .{});
        defer hello_txt.close();
        try hello_txt.writeAll("hello, world!");

        // make file
        var readme = try repo_dir.createFile("README", .{});
        defer readme.close();
        try readme.writeAll("My cool project");

        // add the files
        var index: ?*c.git_index = null;
        try expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try expectEqual(0, c.git_index_add_bypath(index, "hello.txt"));
        try expectEqual(0, c.git_index_add_bypath(index, "README"));
        try expectEqual(0, c.git_index_write(index));

        // make the commit
        var tree_oid: c.git_oid = undefined;
        try expectEqual(0, c.git_index_write_tree(&tree_oid, index));
        var tree: ?*c.git_tree = null;
        try expectEqual(0, c.git_tree_lookup(&tree, repo, &tree_oid));
        defer c.git_tree_free(tree);
        var commit_oid: c.git_oid = undefined;
        var signature: ?*c.git_signature = null;
        try expectEqual(0, c.git_signature_default(&signature, repo));
        defer c.git_signature_free(signature);
        try expectEqual(0, c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null,
            "let there be light",
            tree,
            0,
            null,
        ));
    }

    // add and commit
    {
        // make file
        var license = try repo_dir.createFile("LICENSE", .{});
        defer license.close();
        try license.writeAll("do whatever you want");

        // add the files
        var index: ?*c.git_index = null;
        try expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try expectEqual(0, c.git_index_add_bypath(index, "LICENSE"));
        try expectEqual(0, c.git_index_write(index));

        // get previous commit
        var parent_object: ?*c.git_object = null;
        var ref: ?*c.git_reference = null;
        try expectEqual(0, c.git_revparse_ext(&parent_object, &ref, repo, "HEAD"));
        defer c.git_object_free(parent_object);
        defer c.git_reference_free(ref);
        var parent_commit: ?*c.git_commit = null;
        try expectEqual(0, c.git_commit_lookup(&parent_commit, repo, c.git_object_id(parent_object)));
        defer c.git_commit_free(parent_commit);
        var parents = [_]?*c.git_commit{parent_commit};

        // make the commit
        var tree_oid: c.git_oid = undefined;
        try expectEqual(0, c.git_index_write_tree(&tree_oid, index));
        var tree: ?*c.git_tree = null;
        try expectEqual(0, c.git_tree_lookup(&tree, repo, &tree_oid));
        defer c.git_tree_free(tree);
        var commit_oid: c.git_oid = undefined;
        var signature: ?*c.git_signature = null;
        try expectEqual(0, c.git_signature_default(&signature, repo));
        defer c.git_signature_free(signature);
        try expectEqual(0, c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null,
            "add license",
            tree,
            1,
            &parents,
        ));
    }
}
