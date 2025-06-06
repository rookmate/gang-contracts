// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import "@murky/Merkle.sol";
import "@solady/src/tokens/ERC20.sol";

import "../src/GangVesting.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockERC721.sol";

contract GangVestingTest is Test {
    GangVesting vestContract;
    MockERC20 token;
    MockERC721 nft;
    Merkle merkle;

    address owner = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);
    address user3 = address(0x4);
    address ecosystemAddress = address(0x5);

    bytes32[] public leaves;
    bytes32 public root;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock tokens
        token = new MockERC20("Test Token", "TEST", 18);
        nft = new MockERC721("MOCK NFT", "MNFT");

        merkle = new Merkle();
        setupTestData();

        vestContract = new GangVesting(root, address(token));

        // Mint tokens to owner for vesting
        token.mint(owner, 1000000e18);
        token.approve(address(vestContract), type(uint256).max);
        token.transfer(address(vestContract), 1400e18);

        // Mint NFTs to users
        nft.mint(user1);
        nft.mint(user2);

        vm.stopPrank();
    }

    function setupTestData() internal {
        // Create test data for Gang NFT holders
        leaves = new bytes32[](3);
        leaves[0] = keccak256(
            abi.encodePacked(
                uint8(GangVesting.Collection.Cat),
                user1,
                uint256(100e18),
                uint32(block.timestamp),
                uint32(block.timestamp + 365 days)
            )
        );
        leaves[1] = keccak256(
            abi.encodePacked(
                uint8(GangVesting.Collection.Rat),
                user2,
                uint256(200e18),
                uint32(block.timestamp),
                uint32(block.timestamp + 365 days)
            )
        );
        leaves[2] = keccak256(
            abi.encodePacked(
                uint8(GangVesting.Collection.Dog),
                user3,
                uint256(300e18),
                uint32(block.timestamp + 30 days),
                uint32(block.timestamp + 395 days)
            )
        );

        root = merkle.getRoot(leaves);
    }

    function testInitialSetup() public view {
        bytes32 initialRoot = vestContract.merkleRoot();
        assert(initialRoot == root);
    }

    function testLockRoot() public {
        address attacker = address(0x999);

        // First, try to lock as a non-owner
        vm.prank(attacker);
        vm.expectRevert(); // Should revert due to not being owner
        vestContract.lockRoot();

        // Then lock as the owner
        vm.prank(owner);
        vestContract.lockRoot();
        assertTrue(vestContract.rootLocked());

        // Try to lock again (even by owner)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("RootIsLocked()"));
        vestContract.lockRoot();
    }

    function testCannotUpdateRootAfterLock() public {
        vm.startPrank(owner);
        vestContract.lockRoot();

        vm.expectRevert(abi.encodeWithSignature("RootIsLocked()"));
        vestContract.updateMerkleRoot(bytes32(0));

        vm.stopPrank();
    }

    function testUpdateRoot() public {
        bytes32 newRoot = bytes32(uint256(1));

        vm.prank(owner);
        vestContract.updateMerkleRoot(newRoot);

        bytes32 updatedRoot = vestContract.merkleRoot();
        assertEq(updatedRoot, newRoot);
    }

    function testClaimVesting() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting start
        vm.warp(start + 1 days);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        vestContract.claim(proof, collection, user1, 0, start, end);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        vestContract.claim(proof, collection, user1, amount, end + 1, end);
        vestContract.claim(proof, collection, user1, amount, start, end);

        (GangVesting.Vesting memory vesting,) = vestContract.getVesting(collection, user1, amount, start, end);

        assertGt(vesting.claimed, 0);
        assertEq(vesting.totalClaim, amount);
        assertEq(vesting.recipient, user1);
        assertEq(uint8(vesting.collection), uint8(collection));
    }

    function testCannotClaimTwiceInSameDay() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting start
        vm.warp(start + 1 days);

        vm.startPrank(user1);

        vestContract.claim(proof, collection, user1, amount, start, end);

        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Try to claim again within 1 day
        vm.warp(start + 1.5 days);

        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vestContract.claim(proof, collection, user1, amount, start, end);
    }

    function testCanClaimAfterOneDayOfPreviousClaim() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting start
        vm.warp(start + 1 days);

        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Move forward more than 1 day
        vm.warp(start + 2 days);

        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Verify some tokens were claimed
        (GangVesting.Vesting memory vesting,) = vestContract.getVesting(collection, user1, amount, start, end);

        assertGt(vesting.claimed, 0);
        assertLt(vesting.claimed, amount);
    }

    function testClaimAfterEnd() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting end
        vm.warp(end + 1 days);

        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Should have received full amount
        assertEq(token.balanceOf(user1), amount);
    }

    function testCannotClaimAfterExpiration() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Claim initial vesting
        vm.startPrank(user1);
        vm.warp(start + 1 days);
        vestContract.claim(proof, collection, user1, amount, start, end);
        vm.stopPrank();

        // Move past end and 69 days
        vm.warp(end + 70 days);

        // Try to claim again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vestContract.claim(proof, collection, user1, amount, start, end);
    }

    function testClaimExpiredFunds() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Set ecosystem address
        vm.prank(owner);
        vestContract.setEcosystemAddress(ecosystemAddress);

        // Claim initial vesting
        vm.startPrank(user1);
        vm.warp(start + 1 days);
        vestContract.claim(proof, collection, user1, amount, start, end);
        vm.stopPrank();

        // Move past end and 69 days
        vm.warp(end + 70 days);

        // Check initial balance
        uint256 initialEcosystemBalance = token.balanceOf(ecosystemAddress);

        // Create leaf for ecosystem funds claim
        bytes32 leaf = keccak256(abi.encodePacked(uint8(collection), user1, amount, start, end));

        // Withdraw expired funds
        vm.prank(owner);
        vestContract.claimEcosystemFunds(leaf);

        // Check balance increased
        uint256 finalEcosystemBalance = token.balanceOf(ecosystemAddress);

        assertGt(finalEcosystemBalance, initialEcosystemBalance);
    }

    function testCannotClaimEcosystemFundsTooEarly() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Set ecosystem address
        vm.prank(owner);
        vestContract.setEcosystemAddress(ecosystemAddress);

        // Claim initial vesting
        vm.startPrank(user1);
        vm.warp(start + 1 days);
        vestContract.claim(proof, collection, user1, amount, start, end);
        vm.stopPrank();

        // Move past end but not past expiry window
        vm.warp(end + 30 days);

        // Create leaf for ecosystem funds claim
        bytes32 leaf = keccak256(abi.encodePacked(uint8(collection), user1, amount, start, end));

        // Try to withdraw expired funds too early
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("EcosystemClaimTooEarly()"));
        vestContract.claimEcosystemFunds(leaf);
    }

    function testClaimEcosystemFundsWithNoUnclaimed() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Set ecosystem address
        vm.prank(owner);
        vestContract.setEcosystemAddress(ecosystemAddress);

        // Move to after vesting end and claim all tokens
        vm.warp(end + 1 days);

        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Move past expiry window
        vm.warp(end + 70 days);

        // Record initial balance
        uint256 initialEcosystemBalance = token.balanceOf(ecosystemAddress);

        // Create leaf for ecosystem funds claim
        bytes32 leaf = keccak256(abi.encodePacked(uint8(collection), user1, amount, start, end));

        // Should execute without reverting but do nothing
        vm.prank(owner);
        vestContract.claimEcosystemFunds(leaf);

        // Balance should remain unchanged
        uint256 finalEcosystemBalance = token.balanceOf(ecosystemAddress);
        assertEq(finalEcosystemBalance, initialEcosystemBalance);
    }

    function testVestedAmountCalculation() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting start
        vm.warp(start + 1 days);

        // Claim at start
        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Move forward 181.5 days (50% of vesting period after first claim)
        vm.warp(block.timestamp + 181.5 days);

        (, uint256 vestable) = vestContract.getVesting(collection, user1, amount, start, end);

        // Should be roughly 50% of total amount
        assertApproxEqRel(vestable, amount / 2, 0.01e18); // 1% tolerance
    }

    function testInvalidProof() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        // Use wrong proof (from index 1 instead of 0)
        bytes32[] memory proof = merkle.getProof(leaves, 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidMerkleProof()"));
        vestContract.claim(proof, collection, user1, amount, start, end);
    }

    function testSetEcosystemAddress() public {
        vm.prank(owner);
        vestContract.setEcosystemAddress(ecosystemAddress);

        assertEq(vestContract.ecosystemAddress(), ecosystemAddress);
    }

    function testCannotSetEcosystemAddressAfterLock() public {
        vm.startPrank(owner);
        vestContract.lockRoot();

        vm.expectRevert(abi.encodeWithSignature("RootIsLocked()"));
        vestContract.setEcosystemAddress(ecosystemAddress);

        vm.stopPrank();
    }

    function testCannotSetInvalidEcosystemAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        vestContract.setEcosystemAddress(address(0));
    }

    function testGetVestingBatch() public {
        GangVesting.Collection[] memory collections = new GangVesting.Collection[](2);
        address[] memory recipients = new address[](2);
        uint256[] memory totalClaims = new uint256[](2);
        uint32[] memory starts = new uint32[](2);
        uint32[] memory ends = new uint32[](2);

        collections[0] = GangVesting.Collection.Cat;
        collections[1] = GangVesting.Collection.Rat;

        recipients[0] = user1;
        recipients[1] = user2;

        totalClaims[0] = 100e18;
        totalClaims[1] = 200e18;

        starts[0] = uint32(block.timestamp);
        starts[1] = uint32(block.timestamp);

        ends[0] = uint32(block.timestamp + 365 days);
        ends[1] = uint32(block.timestamp + 365 days);

        // Initial claims
        bytes32[] memory proof1 = merkle.getProof(leaves, 0);
        bytes32[] memory proof2 = merkle.getProof(leaves, 1);

        vm.warp(block.timestamp + 10 days);

        vm.prank(user1);
        vestContract.claim(proof1, collections[0], recipients[0], totalClaims[0], starts[0], ends[0]);

        vm.prank(user2);
        vestContract.claim(proof2, collections[1], recipients[1], totalClaims[1], starts[1], ends[1]);

        // Get batch vestings
        (GangVesting.Vesting[] memory vestings, uint256[] memory amounts) =
            vestContract.getVestingBatch(collections, recipients, totalClaims, starts, ends);

        assertEq(vestings.length, 2);
        assertEq(amounts.length, 2);

        // Check first vesting
        assertEq(uint8(vestings[0].collection), uint8(collections[0]));
        assertEq(vestings[0].recipient, recipients[0]);
        assertEq(vestings[0].totalClaim, totalClaims[0]);

        // Check second vesting
        assertEq(uint8(vestings[1].collection), uint8(collections[1]));
        assertEq(vestings[1].recipient, recipients[1]);
        assertEq(vestings[1].totalClaim, totalClaims[1]);
    }

    function testFullyVestedShouldReturnZeroClaimable() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        bytes32[] memory proof = merkle.getProof(leaves, 0);

        // Move to after vesting end
        vm.warp(end + 1 days);

        vm.prank(user1);
        vestContract.claim(proof, collection, user1, amount, start, end);

        // Check that claimable amount is now zero
        (, uint256 claimable) = vestContract.getVesting(collection, user1, amount, start, end);
        assertEq(claimable, 0);
    }

    // Test calling calculateVesting before start time
    function testCalculateVestingBeforeStart() public view {
        GangVesting.Collection collection = GangVesting.Collection.Dog;
        uint256 amount = 300e18;
        uint32 start = uint32(block.timestamp + 30 days);
        uint32 end = uint32(block.timestamp + 395 days);

        // Check vesting before start time
        (, uint256 vestable) = vestContract.getVesting(collection, user3, amount, start, end);

        // Should be 0 before start time
        assertEq(vestable, 0);
    }

    // Test array length mismatch in getVestingBatch
    function testGetVestingBatchArrayMismatch() public {
        GangVesting.Collection[] memory collections = new GangVesting.Collection[](2);
        address[] memory recipients = new address[](2);
        uint256[] memory totalClaims = new uint256[](3); // Mismatched length
        uint32[] memory starts = new uint32[](2);
        uint32[] memory ends = new uint32[](2);

        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMustMatch()"));
        vestContract.getVestingBatch(collections, recipients, totalClaims, starts, ends);
    }

    // Test vesting that's passed expiry window
    function testVestingPastExpiryWindowReturnsZero() public {
        GangVesting.Collection collection = GangVesting.Collection.Cat;
        uint256 amount = 100e18;
        uint32 start = uint32(block.timestamp);
        uint32 end = uint32(block.timestamp + 365 days);

        // Move far past the end date and expiry window
        vm.warp(end + 100 days);

        (, uint256 vestable) = vestContract.getVesting(collection, user1, amount, start, end);

        // Should be 0 after expiry window
        assertEq(vestable, 0);
    }

    function testVestingBeforeStartReturnsZero() public {
        // Create a vesting that starts in the future
        uint32 futureStart = uint32(block.timestamp + 30 days);
        uint32 futureEnd = uint32(block.timestamp + 395 days);
        uint256 amount = 300e18;

        // Manually generate the hash for the single leaf
        bytes32 futureLeaf =
            keccak256(abi.encodePacked(uint8(GangVesting.Collection.Dog), user1, amount, futureStart, futureEnd));

        // Manually create a single-element array for leaves
        bytes32[] memory futureLeaves = new bytes32[](1);
        futureLeaves[0] = futureLeaf;

        // Manually generate root by returning the leaf itself if only one leaf
        bytes32 futureRoot = futureLeaves[0];

        // Redeploy contract with new root
        vm.prank(owner);
        vestContract = new GangVesting(futureRoot, address(token));

        // Prepare merkle proof (which will be empty for a single leaf)
        bytes32[] memory proof = new bytes32[](0);

        // Check vesting details before start time
        (, uint256 vestable) =
            vestContract.getVesting(GangVesting.Collection.Dog, user1, amount, futureStart, futureEnd);

        // Should be 0 before start time
        assertEq(vestable, 0, "Vesting amount should be zero before start time");

        // Attempt to claim before start time should also return zero
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vestContract.claim(proof, GangVesting.Collection.Dog, user1, amount, futureStart, futureEnd);
    }
}
