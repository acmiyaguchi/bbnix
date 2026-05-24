#include <iostream>
#include <stdexcept>
#include <string>

int
main ()
{
  try
    {
      std::string msg = "bbnix: hello from arm-nto-qnx (C++)";
      throw std::runtime_error (msg);
    }
  catch (const std::exception &e)
    {
      std::cout << e.what () << std::endl;
    }
  return 0;
}
