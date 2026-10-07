using System;
using System.Text.Json;

internal static class Program
{
    private const string Usage = "usage: request validate --request <file> | task plan --request <file> --tasks-root <dir> [--ctx-config-root <dir>] [--ctx-external-profiles-root <dir>] | task apply --request <file> --tasks-root <dir> --expected-plan-identity <sha256-hex> [--ctx-config-root <dir>] [--ctx-external-profiles-root <dir>]";

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 4 && args[0] == "request" && args[1] == "validate" && args[2] == "--request")
            {
                var result = RequestValidator.Validate(args[3]);
                Console.Out.Write(JsonSerializer.Serialize(result));
                return 0;
            }

            if (args.Length >= 2 && args[0] == "task" && args[1] == "plan")
            {
                var options = ParseTaskOptions(args, allowExpectedPlanIdentity: false);
                var validation = RequestValidator.Validate(options.RequestPath, allowTaskFiles: true);
                var plan = TaskPlanner.Plan(validation.Normalized, options.TasksRoot, options.CtxRoots);
                Console.Out.Write(JsonSerializer.Serialize(plan));
                return 0;
            }

            if (args.Length >= 2 && args[0] == "task" && args[1] == "apply")
            {
                var options = ParseTaskOptions(args, allowExpectedPlanIdentity: true);
                var validation = RequestValidator.Validate(options.RequestPath, allowTaskFiles: true);
                var result = TaskApplier.Apply(validation.Normalized, options.TasksRoot, options.ExpectedPlanIdentity, options.CtxRoots);
                Console.Out.Write(JsonSerializer.Serialize(result));
                return 0;
            }

            throw new InputException(Usage);
        }
        catch (InputException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
        catch (OperationalException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static ParsedTaskOptions ParseTaskOptions(string[] args, bool allowExpectedPlanIdentity)
    {
        string? requestPath = null;
        string? tasksRoot = null;
        string? expectedPlanIdentity = null;
        string? ctxConfigRoot = null;
        string? ctxExternalProfilesRoot = null;

        for (var index = 2; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length)
            {
                throw new InputException(Usage);
            }

            var name = args[index];
            var value = args[index + 1];
            switch (name)
            {
                case "--request":
                    if (requestPath is not null)
                    {
                        throw new InputException(Usage);
                    }

                    requestPath = value;
                    break;
                case "--tasks-root":
                    if (tasksRoot is not null)
                    {
                        throw new InputException(Usage);
                    }

                    tasksRoot = value;
                    break;
                case "--expected-plan-identity":
                    if (!allowExpectedPlanIdentity || expectedPlanIdentity is not null)
                    {
                        throw new InputException(Usage);
                    }

                    expectedPlanIdentity = value;
                    break;
                case "--ctx-config-root":
                    if (ctxConfigRoot is not null)
                    {
                        throw new InputException(Usage);
                    }

                    ctxConfigRoot = value;
                    break;
                case "--ctx-external-profiles-root":
                    if (ctxExternalProfilesRoot is not null)
                    {
                        throw new InputException(Usage);
                    }

                    ctxExternalProfilesRoot = value;
                    break;
                default:
                    throw new InputException(Usage);
            }
        }

        if (requestPath is null || tasksRoot is null)
        {
            throw new InputException(Usage);
        }

        return new ParsedTaskOptions
        {
            RequestPath = requestPath,
            TasksRoot = tasksRoot,
            ExpectedPlanIdentity = expectedPlanIdentity,
            CtxRoots = new CtxRootOptions
            {
                ConfigRoot = ctxConfigRoot,
                ExternalProfilesRoot = ctxExternalProfilesRoot,
            },
        };
    }

    private sealed class ParsedTaskOptions
    {
        public string RequestPath { get; init; } = string.Empty;

        public string TasksRoot { get; init; } = string.Empty;

        public string? ExpectedPlanIdentity { get; init; }

        public CtxRootOptions CtxRoots { get; init; } = new();
    }
}
