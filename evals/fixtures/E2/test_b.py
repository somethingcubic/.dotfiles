import unittest

from b import total


class BTest(unittest.TestCase):
    def test_total_counts_every_item(self):
        self.assertEqual(total([3, 4, 5]), 12)


if __name__ == "__main__":
    unittest.main()
