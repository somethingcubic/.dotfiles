import unittest

from a import greet


class ATest(unittest.TestCase):
    def test_greet_keeps_case(self):
        self.assertEqual(greet("Ana"), "Hello, Ana")


if __name__ == "__main__":
    unittest.main()
