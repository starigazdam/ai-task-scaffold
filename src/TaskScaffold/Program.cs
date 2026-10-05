using System;
using System.Text.Json;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 4 || args[0] != "request" || args[1] != "validate" || args[2] != "--request")
            {
                throw new InputException("usage: request validate --request <file>");
            }

            var result = RequestValidator.Validate(args[3]);
            Console.Out.Write(JsonSerializer.Serialize(result));
            return 0;
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
