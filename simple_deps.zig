const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const mem = std.mem;
const ArrayList = std.ArrayList;

fn extractImports(allocator: mem.Allocator, file_path: []const u8) !ArrayList([]const u8) {
    var imports = ArrayList([]const u8).init(allocator);
    
    const file = fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            print("Warning: File not found: {s}\n", .{file_path});
            return imports;
        }
        return err;
    };
    defer file.close();
    
    const source = try file.readToEndAllocOptions(allocator, 1024 * 1024, null, @alignOf(u8), 0);
    defer allocator.free(source);
    
    var ast = std.zig.Ast.parse(allocator, source, .zig) catch |err| {
        print("Warning: Failed to parse {s}: {}\n", .{ file_path, err });
        return imports;
    };
    defer ast.deinit(allocator);
    
    for (0..ast.nodes.len) |i| {
        const node = ast.nodes.get(i);
        
        if (node.tag == .builtin_call_two) {
            const main_token = node.main_token;
            
            if (main_token < ast.tokens.len and mem.eql(u8, ast.tokenSlice(main_token), "@import")) {
                const param_node_idx = node.data.lhs;
                
                if (param_node_idx < ast.nodes.len) {
                    const param_node = ast.nodes.get(param_node_idx);
                    
                    if (param_node.tag == .string_literal) {
                        const import_str = ast.tokenSlice(param_node.main_token);
                        if (import_str.len >= 2) {
                            const clean_import = import_str[1..import_str.len-1];
                            try imports.append(try allocator.dupe(u8, clean_import));
                        }
                    }
                }
            }
        }
    }
    
    return imports;
}

fn analyzeFileRecursive(allocator: mem.Allocator, file_path: []const u8, depth: u32, visited: *std.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) !void {
    // Avoid infinite recursion
    if (visited.contains(file_path) or depth > 6) {
        for (0..depth) |_| print("  ", .{});
        if (visited.contains(file_path)) {
            print("{s} (already analyzed)\n", .{file_path});
        } else {
            print("{s} (max depth)\n", .{file_path});
        }
        return;
    }
    
    const owned_path = try allocator.dupe(u8, file_path);
    try visited.put(owned_path, {});
    
    // Print current file
    for (0..depth) |_| print("  ", .{});
    print("{s}\n", .{file_path});
    
    // Get imports
    var imports = extractImports(allocator, file_path) catch |err| {
        for (0..depth + 1) |_| print("  ", .{});
        print("Error reading {s}: {}\n", .{file_path, err});
        return;
    };
    defer {
        for (imports.items) |import| allocator.free(import);
        imports.deinit();
    }
    
    // Process each import
    for (imports.items) |import_path| {
        if (mem.startsWith(u8, import_path, "std") or 
            mem.startsWith(u8, import_path, "zzz") or
            mem.startsWith(u8, import_path, "clap") or
            mem.startsWith(u8, import_path, "yaml")) {
            for (0..depth + 1) |_| print("  ", .{});
            print("{s} (external)\n", .{import_path});
        } else {
            // Simple path resolution
            var resolved_path: []const u8 = undefined;
            if (mem.startsWith(u8, import_path, "src/")) {
                resolved_path = import_path;
            } else if (mem.startsWith(u8, import_path, "../")) {
                // Handle relative paths - this is basic, might need improvement
                if (mem.indexOf(u8, file_path, "/")) |last_slash| {
                    const dir = file_path[0..last_slash];
                    if (mem.lastIndexOf(u8, dir, "/")) |parent_slash| {
                        const parent_dir = file_path[0..parent_slash];
                        const relative_part = import_path[3..]; // Skip "../"
                        var path_buf = ArrayList(u8).init(allocator);
                        defer path_buf.deinit();
                        try path_buf.appendSlice(parent_dir);
                        try path_buf.append('/');
                        try path_buf.appendSlice(relative_part);
                        resolved_path = try path_buf.toOwnedSlice();
                        defer allocator.free(resolved_path);
                    } else {
                        resolved_path = import_path[3..]; // Just remove "../"
                    }
                } else {
                    resolved_path = import_path[3..];
                }
            } else {
                // Same directory
                if (mem.lastIndexOf(u8, file_path, "/")) |last_slash| {
                    const dir = file_path[0..last_slash];
                    var path_buf = ArrayList(u8).init(allocator);
                    defer path_buf.deinit();
                    try path_buf.appendSlice(dir);
                    try path_buf.append('/');
                    try path_buf.appendSlice(import_path);
                    resolved_path = try path_buf.toOwnedSlice();
                    defer allocator.free(resolved_path);
                } else {
                    resolved_path = import_path;
                }
            }
            
            try analyzeFileRecursive(allocator, resolved_path, depth + 1, visited);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        print("Usage: {s} <file.zig>\n", .{args[0]});
        return;
    }
    
    var visited = std.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer {
        var iter = visited.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }
    
    print("Complete dependency tree for {s}:\n", .{args[1]});
    try analyzeFileRecursive(allocator, args[1], 0, &visited);
}