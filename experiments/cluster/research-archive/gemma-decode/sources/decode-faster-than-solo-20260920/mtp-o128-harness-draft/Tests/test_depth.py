"""Pure reader controls; synthetic values cannot qualify a native execution."""
import sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BASE=Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-packed-head-physical-20260920')
sys.path[:0]=[str(ROOT/'proposed/remote/package'),str(BASE/'package')]
from remote_mtp_contract import verification_depth,validate_metadata_depth,validate_verification_widths
class Depth(unittest.TestCase):
    def test_both_chosen_depths_accept(self):
        for depth in [1,2]:
            self.assertEqual(verification_depth(dict(maximumDraftTokens=depth)),depth)
            validate_metadata_depth(dict(maximumDraftTokens=depth,maximumBufferedProposals=5),dict(maximumDraftTokens=depth))
    def test_depth_is_an_exact_bounded_integer(self):
        for depth in [False,True,1.0,2.0,0,3,-1,'1',None]:
            with self.assertRaises(ValueError):verification_depth(dict(maximumDraftTokens=depth))
    def test_metadata_cannot_substitute_peer_depth(self):
        for local,reported in [(1,2),(2,1),(1,True),(2,2.0)]:
            with self.assertRaises(ValueError):validate_metadata_depth(dict(maximumDraftTokens=reported,maximumBufferedProposals=5),dict(maximumDraftTokens=local))
    def test_producer_queue_stays_five_at_either_depth(self):
        for depth in [1,2]:
            for count in [2,4,6,True,5.0]:
                with self.assertRaises(ValueError):validate_metadata_depth(dict(maximumDraftTokens=depth,maximumBufferedProposals=count),dict(maximumDraftTokens=depth))
    def test_depth_one_accepts_prime_tail_and_two_column_windows(self):
        validate_verification_widths([1,2,2,1],dict(maximumDraftTokens=1))
        with self.assertRaises(ValueError):validate_verification_widths([1,2,3],dict(maximumDraftTokens=1))
    def test_depth_two_preserves_three_column_windows(self):
        validate_verification_widths([1,3,2,1],dict(maximumDraftTokens=2))
    def test_malformed_or_unprimed_widths_refuse(self):
        for widths in [[],[2],[1,0],[1,4],[True,2],[1,2.0],(1,2)]:
            with self.assertRaises(ValueError):validate_verification_widths(widths,dict(maximumDraftTokens=2))
if __name__=='__main__':unittest.main()
