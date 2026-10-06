using System;
using System.Text.Json;

internal static class Program
{
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

            if (args.Length == 6 && args[0] == "task" && args[1] == "plan" && args[2] == "--request" && args[4] == "--tasks-root")
            {
                var validation = RequestValidator.Validate(args[3], allowTaskFiles: true);
                var plan = TaskPlanner.Plan(validation.Normalized, args[5]);
                Console.Out.Write(JsonSerializer.Serialize(plan));
                return 0;
            }

            if (args.Length == 8 && args[0] == "task" && args[1] == "apply" && args[2] == "--request" && args[4] == "--tasks-root" && args[6] == "--expected-plan-identity")
            {
                var validation = RequestValidator.Validate(args[3], allowTaskFiles: true);
                var result = TaskApplier.Apply(validation.Normalized, args[5], args[7]);
                Console.Out.Write(JsonSerializer.Serialize(result));
                return 0;
            }

            if (args.Length == 6 && args[0] == "task" && args[1] == "apply" && args[2] == "--request" && args[4] == "--tasks-root")
            {
                var validation = RequestValidator.Validate(args[3], allowTaskFiles: true);
                var result = TaskApplier.Apply(validation.Normalized, args[5], null);
                Console.Out.Write(JsonSerializer.Serialize(result));
                return 0;
            }

            throw new InputException("usage: request validate --request <file> | task plan --request <file> --tasks-root <dir> | task apply --request <file> --tasks-root <dir> --expected-plan-identity <sha256-hex>");
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
}
