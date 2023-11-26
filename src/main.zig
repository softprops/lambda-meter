const std = @import("std");
const clap = @import("clap");

const QueryResults = struct {
    results: [][]struct {
        field: []const u8,
        value: []const u8,
    },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-f, --function <string> The name of the function. This is convenience for -l /aws/lambda/{function}
        \\-l, --log_group <string> The name of the function log group
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(
        clap.Help,
        &params,
        clap.parsers.default,
        .{
            .diagnostic = &diag,
        },
    ) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        _ = try std.io.getStdErr().writer().write("fetch aws lambda function metrics\n");
        return clap.help(
            std.io.getStdErr().writer(),
            clap.Help,
            &params,
            .{},
        );
    }

    var maybe_log_group = res.args.log_group orelse blk: {
        if (res.args.function) |func| {
            break :blk std.fmt.allocPrint(
                allocator,
                "/aws/lambda/{s}",
                .{func},
            ) catch null;
        } else {
            break :blk null;
        }
    };

    if (maybe_log_group) |log_group| {
        std.debug.print(
            "fetching logs for {s}...\n",
            .{log_group},
        );
        var start_query = try std.ChildProcess.exec(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "aws",
                "logs",
                "start-query",
                "--log-group-name",
                log_group,
                "--query-string",
                \\filter @type = "REPORT" | parse @log /\d+:\/aws\/lambda\/(?<function>.+)/ | stats count(*) as invocations,pct(@duration, 0) as p0,pct(@duration, 25) as p25,pct(@duration, 50) as p50,pct(@duration, 75) as p75,pct(@duration, 90) as p90,pct(@duration, 95) as p95,pct(@duration, 99) as p99, pct(@duration, 100) as p100 group by function, ispresent(@initDuration) as coldstart | sort by function, coldstart
                ,
                "--start-time",
                try std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{std.time.milliTimestamp() - (20 * std.time.ms_per_min)},
                ),
                "--end-time",
                try std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{std.time.milliTimestamp()},
                ),
                "--output",
                "text",
            },
        });
        const query_id = std.mem.trimRight(
            u8,
            start_query.stdout,
            "\n",
        );
        if (query_id.len != 0) {
            std.time.sleep(1 * std.time.ns_per_s);
            var query_result = try std.ChildProcess.exec(.{
                .allocator = allocator,
                .argv = &[_][]const u8{
                    "aws",
                    "logs",
                    "get-query-results",
                    "--query-id",
                    query_id,
                    "--output",
                    "json",
                },
            });
            var query_results = std.mem.trim(
                u8,
                query_result.stdout,
                "\n",
            );
            var parsed = try std.json.parseFromSlice(
                QueryResults,
                allocator,
                query_results,
                .{ .ignore_unknown_fields = true },
            );

            var stdout = std.io.getStdOut().writer();
            // todo: prettier table view
            for (parsed.value.results, 0..) |rows, i| {
                if (i == 0) {
                    for (rows) |row| {
                        try stdout.print("{s}\t", .{row.field});
                    }
                    try stdout.print("\n", .{});
                }
                for (rows) |row| {
                    try stdout.print("{s}\t", .{row.value});
                }
                try stdout.print("\n", .{});
            }

            //std.debug.print("parsed {any}", .{parsed.value});
        } else {
            std.debug.print("{s}", .{start_query.stderr});
        }
    } else {
        _ = try std.io.getStdErr().writer().write(
            "function or log_group is required",
        );
    }
}
