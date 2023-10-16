const std = @import("std");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

test {
    _ = @import("./main.zig");
    _ = @import("./ndslice.zig");
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
    if (cwd.openFile(temp_dir_name, .{})) |file| {
        file.close();
        try cwd.deleteTree(temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.makeOpenPath(temp_dir_name, .{});
    defer cwd.deleteTree(temp_dir_name) catch {};
    defer temp_dir.close();

    // create the repo dir
    var repo_dir = try temp_dir.makeOpenPath("repo", .{});
    defer repo_dir.close();

    // get repo path for libgit
    var repo_path_buffer = [_]u8{0} ** std.fs.MAX_PATH_BYTES;
    const repo_path: [*c]const u8 = @ptrCast(try repo_dir.realpath(".", &repo_path_buffer));

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

        // change file
        const hello_txt = try repo_dir.openFile("hello.txt", .{ .mode = .read_write });
        defer hello_txt.close();
        try hello_txt.writeAll("goodbye, world!");
        try hello_txt.setEndPos(try hello_txt.getPos());

        // add the files
        var index: ?*c.git_index = null;
        try expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try expectEqual(0, c.git_index_add_bypath(index, "LICENSE"));
        try expectEqual(0, c.git_index_add_bypath(index, "hello.txt"));
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

    // walk the commits
    {
        // init walker
        var walker: ?*c.git_revwalk = null;
        try expectEqual(0, c.git_revwalk_new(&walker, repo));
        defer c.git_revwalk_free(walker);
        try expectEqual(0, c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
        try expectEqual(0, c.git_revwalk_push_head(walker));

        // init commits list
        var commits = std.ArrayList(?*c.git_commit).init(allocator);
        defer {
            for (commits.items) |commit| {
                c.git_commit_free(commit);
            }
            commits.deinit();
        }

        // walk the commits
        var oid: c.git_oid = undefined;
        while (0 == c.git_revwalk_next(&oid, walker)) {
            var commit: ?*c.git_commit = null;
            try expectEqual(0, c.git_commit_lookup(&commit, repo, &oid));
            {
                errdefer c.git_commit_free(commit);
                try commits.append(commit);
            }
        }

        // check the commit messages
        try expectEqual(2, commits.items.len);
        try std.testing.expectEqualStrings("add license", std.mem.sliceTo(c.git_commit_message(commits.items[0]), 0));
        try std.testing.expectEqualStrings("let there be light", std.mem.sliceTo(c.git_commit_message(commits.items[1]), 0));

        // diff the commits
        for (0..commits.items.len) |i| {
            const commit = commits.items[i];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            try expectEqual(0, c.git_tree_lookup(&commit_tree, repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (i < commits.items.len - 1) {
                const prev_commit = commits.items[i + 1];
                const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                try expectEqual(0, c.git_tree_lookup(&prev_commit_tree, repo, prev_commit_oid));
            }
            defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

            var commit_diff: ?*c.git_diff = null;
            try expectEqual(0, c.git_diff_tree_to_tree(&commit_diff, repo, prev_commit_tree, commit_tree, null));
            defer c.git_diff_free(commit_diff);

            const delta_count = c.git_diff_num_deltas(commit_diff);
            for (0..delta_count) |delta_index| {
                var commit_patch: ?*c.git_patch = null;
                try expectEqual(0, c.git_patch_from_diff(&commit_patch, commit_diff, delta_index));
                defer c.git_patch_free(commit_patch);

                var commit_buf: c.git_buf = std.mem.zeroes(c.git_buf);
                try expectEqual(0, c.git_patch_to_buf(&commit_buf, commit_patch));
                defer c.git_buf_dispose(&commit_buf);
            }
        }
    }

    // status
    {
        // make file
        var goodbye_txt = try repo_dir.createFile("goodbye.txt", .{});
        defer goodbye_txt.close();
        try goodbye_txt.writeAll("Goodbye");

        // make dirs
        var a_dir = try repo_dir.makeOpenPath("a", .{});
        defer a_dir.close();
        var b_dir = try repo_dir.makeOpenPath("b", .{});
        defer b_dir.close();
        var c_dir = try repo_dir.makeOpenPath("c", .{});
        defer c_dir.close();

        // make file in dir
        var farewell_txt = try a_dir.createFile("farewell.txt", .{});
        defer farewell_txt.close();
        try farewell_txt.writeAll("Farewell");

        // modify indexed files
        const hello_txt = try repo_dir.openFile("hello.txt", .{ .mode = .read_write });
        defer hello_txt.close();
        try hello_txt.writeAll("hello, world again!");
        try repo_dir.deleteFile("LICENSE");

        // get status
        var status_list: ?*c.git_status_list = null;
        var status_options: c.git_status_options = undefined;
        try expectEqual(0, c.git_status_options_init(&status_options, c.GIT_STATUS_OPTIONS_VERSION));
        status_options.show = c.GIT_STATUS_SHOW_WORKDIR_ONLY;
        status_options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED;
        try expectEqual(0, c.git_status_list_new(&status_list, repo, &status_options));
        defer c.git_status_list_free(status_list);
        try expectEqual(4, c.git_status_list_entrycount(status_list));
    }
}
