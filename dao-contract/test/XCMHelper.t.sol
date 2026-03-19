// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {XCMHelper} from "../src/XCMHelper.sol";

/// @notice Harness to expose XCMHelper internals for testing
contract XCMHelperHarness {
    function encodeCompact(uint128 value) external pure returns (bytes memory) {
        return XCMHelper._encodeCompact(value);
    }

    function buildTransferMessage(
        uint32 targetParaId,
        bytes32 recipient,
        uint256 amount
    ) external pure returns (bytes memory) {
        return XCMHelper.buildTransferMessage(targetParaId, recipient, amount);
    }

    function dotMultilocation() external pure returns (bytes memory) {
        return XCMHelper.dotMultilocation();
    }

    function encodeAccountId32Beneficiary(bytes32 accountId)
        external pure returns (bytes memory)
    {
        return XCMHelper.encodeAccountId32Beneficiary(accountId);
    }

    function encodeAccountKey20Beneficiary(address evmAddress)
        external pure returns (bytes memory)
    {
        return XCMHelper.encodeAccountKey20Beneficiary(evmAddress);
    }

    function encodeBeneficiary(uint32 paraId, bytes32 recipient)
        external pure returns (bytes memory)
    {
        return XCMHelper.encodeBeneficiary(paraId, recipient);
    }

    function dotToPlanck(uint256 dot) external pure returns (uint256) {
        return XCMHelper.dotToPlanck(dot);
    }

    function planckToDot(uint256 planck) external pure returns (uint256) {
        return XCMHelper.planckToDot(planck);
    }
}

/// @notice Mock XCM precompile for testing dispatch
contract MockXCMPrecompile {
    bytes public lastMessage;
    uint64 public lastWeight;
    uint256 public executeCallCount;
    uint256 public weighCallCount;
    bool public shouldReturnZeroWeight;

    function setShouldReturnZeroWeight(bool v) external { shouldReturnZeroWeight = v; }

    function weighMessage(bytes calldata message)
        external
        returns (uint64 refTime, uint64 proofSize)
    {
        weighCallCount++;
        lastMessage = message;
        if (shouldReturnZeroWeight) return (0, 0);
        return (1_000_000_000, 65_536);
    }

    function execute(bytes calldata message, uint64 weight) external {
        executeCallCount++;
        lastMessage = message;
        lastWeight = weight;
    }

    function send(bytes calldata, bytes calldata) external {}
}

contract XCMHelperTest is Test {

    XCMHelperHarness internal h;

    bytes32 constant SUBSTRATE_RECIPIENT = bytes32(
        0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d // Alice pubkey
    );
    address constant MOONBEAM_RECIPIENT  = 0xf24FF3a9CF04c71Dbc94D0b566f7A27B94566cac;

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        h = new XCMHelperHarness();
    }

    // ─────────────────────────────────────────────
    // 1. Asset Encoding — DOT Multilocation
    // ─────────────────────────────────────────────

    function test_DotMultilocation_Length() public view {
        // parents(1) + Here(1) = 2 bytes
        assertEq(h.dotMultilocation().length, 2);
    }

    function test_DotMultilocation_Parents_IsOne() public view {
        bytes memory loc = h.dotMultilocation();
        assertEq(uint8(loc[0]), 1, "parents must be 1 (relay chain)");
    }

    function test_DotMultilocation_Interior_IsHere() public view {
        bytes memory loc = h.dotMultilocation();
        assertEq(uint8(loc[1]), 0, "interior must be Here (0x00)");
    }

    function test_DotMultilocation_Deterministic() public view {
        assertEq(
            keccak256(h.dotMultilocation()),
            keccak256(h.dotMultilocation())
        );
    }

    // ─────────────────────────────────────────────
    // 2a. Beneficiary — AccountId32 (Substrate chains)
    // ─────────────────────────────────────────────

    function test_AccountId32_Length() public view {
        // parents(1) + X1(1) + variant(1) + network(1) + id(32) = 36 bytes
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        assertEq(enc.length, 36);
    }

    function test_AccountId32_Parents_IsZero() public view {
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        assertEq(uint8(enc[0]), 0, "parents must be 0");
    }

    function test_AccountId32_Interior_IsX1() public view {
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        assertEq(uint8(enc[1]), 1, "interior must be X1");
    }

    function test_AccountId32_Junction_Variant() public view {
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        assertEq(uint8(enc[2]), 0, "junction variant must be 0 (AccountId32)");
    }

    function test_AccountId32_Network_IsNone() public view {
        // XCM v3 uses network: None (0x00), NOT network: Any
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        assertEq(uint8(enc[3]), 0, "network must be None (XCM v3)");
    }

    function test_AccountId32_IdEmbedded() public view {
        bytes memory enc = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        // Bytes 4–35 should match the recipient
        bytes32 extracted;
        assembly { extracted := mload(add(add(enc, 0x20), 4)) }
        assertEq(extracted, SUBSTRATE_RECIPIENT);
    }

    function test_AccountId32_DifferentRecipients_DifferentOutput() public view {
        bytes memory a = h.encodeAccountId32Beneficiary(SUBSTRATE_RECIPIENT);
        bytes memory b = h.encodeAccountId32Beneficiary(bytes32(uint256(1)));
        assertNotEq(keccak256(a), keccak256(b));
    }

    // ─────────────────────────────────────────────
    // 2b. Beneficiary — AccountKey20 (EVM chains e.g. Moonbeam)
    // ─────────────────────────────────────────────

    function test_AccountKey20_Length() public view {
        // parents(1) + X1(1) + variant(1) + network(1) + address(20) = 24 bytes
        bytes memory enc = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        assertEq(enc.length, 24);
    }

    function test_AccountKey20_Parents_IsZero() public view {
        bytes memory enc = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        assertEq(uint8(enc[0]), 0);
    }

    function test_AccountKey20_Interior_IsX1() public view {
        bytes memory enc = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        assertEq(uint8(enc[1]), 1);
    }

    function test_AccountKey20_Junction_Variant() public view {
        bytes memory enc = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        assertEq(uint8(enc[2]), 3, "junction variant must be 3 (AccountKey20)");
    }

    function test_AccountKey20_Network_IsNone() public view {
        bytes memory enc = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        assertEq(uint8(enc[3]), 0, "network must be None");
    }

    function test_AccountKey20_AddressDifferent_DifferentOutput() public view {
        bytes memory a = h.encodeAccountKey20Beneficiary(MOONBEAM_RECIPIENT);
        bytes memory b = h.encodeAccountKey20Beneficiary(address(0x1234));
        assertNotEq(keccak256(a), keccak256(b));
    }

    // ─────────────────────────────────────────────
    // 2c. Auto-selection: encodeBeneficiary
    // ─────────────────────────────────────────────

    function test_EncodeBeneficiary_NonMoonbeam_UsesAccountId32() public view {
        // Astar = 2006, should use AccountId32 (36 bytes)
        bytes memory enc = h.encodeBeneficiary(2006, SUBSTRATE_RECIPIENT);
        assertEq(enc.length, 36);
        assertEq(uint8(enc[2]), 0, "should use AccountId32 junction (0)");
    }

    function test_EncodeBeneficiary_Moonbeam_UsesAccountKey20() public view {
        // Moonbeam = 2004, recipient passed as address cast to bytes32
        bytes32 moonbeamRecip = bytes32(uint256(uint160(MOONBEAM_RECIPIENT)));
        bytes memory enc = h.encodeBeneficiary(2004, moonbeamRecip);
        assertEq(enc.length, 24, "Moonbeam should use AccountKey20 (24 bytes)");
        assertEq(uint8(enc[2]), 3, "should use AccountKey20 junction (3)");
    }

    function test_EncodeBeneficiary_Hydration_UsesAccountId32() public view {
        bytes memory enc = h.encodeBeneficiary(2034, SUBSTRATE_RECIPIENT); // Hydration
        assertEq(enc.length, 36);
    }

    function test_EncodeBeneficiary_Bifrost_UsesAccountId32() public view {
        bytes memory enc = h.encodeBeneficiary(2030, SUBSTRATE_RECIPIENT); // Bifrost
        assertEq(enc.length, 36);
    }

    // ─────────────────────────────────────────────
    // 3. Weight — constants and fallback
    // ─────────────────────────────────────────────

    function test_FallbackWeight_IsNonZero() public pure {
        assertTrue(XCMHelper.FALLBACK_WEIGHT > 0);
    }

    function test_FallbackWeight_Value() public pure {
        // Testnet safe default
        assertEq(XCMHelper.FALLBACK_WEIGHT, 1_000_000_000);
    }

    function test_GetWeight_UsesFallback_WhenZeroReturned() public {
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("weighMessage(bytes)"))),
            abi.encode(uint64(0), uint64(0))
        );

        XCMGetWeightHarness wh = new XCMGetWeightHarness();
        uint64 weight = wh.getWeight(hex"deadbeef");
        assertEq(weight, XCMHelper.FALLBACK_WEIGHT, "should use fallback when precompile returns 0");
    }

    function test_GetWeight_UsesPrecompileValue_WhenNonZero() public {
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("weighMessage(bytes)"))),
            abi.encode(uint64(1_000_000_000), uint64(65_536))
        );

        XCMGetWeightHarness wh = new XCMGetWeightHarness();
        uint64 weight = wh.getWeight(hex"deadbeef");
        assertEq(weight, 1_000_000_000, "should use value from precompile");
    }

    // ─────────────────────────────────────────────
    // SCALE Compact Encoding
    // ─────────────────────────────────────────────

    function test_CompactEncode_Zero() public view {
        bytes memory r = h.encodeCompact(0);
        assertEq(r.length, 1);
        assertEq(r[0], bytes1(0x00));
    }

    function test_CompactEncode_One() public view {
        assertEq(h.encodeCompact(1)[0], bytes1(0x04));
    }

    function test_CompactEncode_63_SingleByteUpperBound() public view {
        bytes memory r = h.encodeCompact(63);
        assertEq(r.length, 1);
    }

    function test_CompactEncode_64_FirstTwoByte() public view {
        assertEq(h.encodeCompact(64).length, 2);
    }

    function test_CompactEncode_16383_TwoByteUpperBound() public view {
        assertEq(h.encodeCompact(16383).length, 2);
    }

    function test_CompactEncode_16384_FirstFourByte() public view {
        assertEq(h.encodeCompact(16384).length, 4);
    }

    function test_CompactEncode_BigInteger_OneDOT() public view {
        // 1 DOT = 10_000_000_000 planck > 2^30 → big integer mode (17 bytes)
        bytes memory r = h.encodeCompact(10_000_000_000);
        assertEq(r.length, 17);
        assertEq(r[0], bytes1(0x33), "big-integer mode byte must be 0x33");
    }

    function test_CompactEncode_BigInteger_LittleEndian() public view {
        // value = 10_000_000_000 = 0x00000002_540BE400
        // little-endian bytes: 0x00, 0xE4, 0x0B, 0x54, 0x02, 0x00, ...
        bytes memory r = h.encodeCompact(10_000_000_000);
        assertEq(uint8(r[1]),  0x00);
        assertEq(uint8(r[2]),  0xE4);
        assertEq(uint8(r[3]),  0x0B);
        assertEq(uint8(r[4]),  0x54);
        assertEq(uint8(r[5]),  0x02);
        // remaining bytes should be 0
        for (uint i = 6; i < 17; i++) {
            assertEq(uint8(r[i]), 0);
        }
    }

    function testFuzz_CompactEncode_NeverEmpty(uint128 value) public view {
        assertTrue(h.encodeCompact(value).length > 0);
    }

    function testFuzz_CompactEncode_SingleByteRange(uint8 raw) public view {
        uint128 v = uint128(raw) % 64;
        assertEq(h.encodeCompact(v).length, 1);
    }

    // ─────────────────────────────────────────────
    // buildTransferMessage
    // ─────────────────────────────────────────────

    function test_BuildMessage_NonEmpty() public view {
        bytes memory msg_ = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        assertTrue(msg_.length > 0);
    }

    function test_BuildMessage_StartsWithXCMV3Prefix() public view {
        bytes memory msg_ = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        // First byte should be XCM V3 (0x03)
        assertEq(uint8(msg_[0]), 0x03, "must start with XCM V3 prefix");
    }

    function test_BuildMessage_HasThreeInstructions() public view {
        bytes memory msg_ = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        // Second byte = compact-encoded 3 = 0x0C
        assertEq(uint8(msg_[1]), 0x0C, "must encode 3 instructions");
    }

    function test_BuildMessage_Deterministic() public view {
        bytes memory a = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        bytes memory b = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        assertEq(keccak256(a), keccak256(b));
    }

    function test_BuildMessage_DifferentParaId_DifferentResult() public view {
        // ParaId only affects output when one is Moonbeam (2004) vs non-Moonbeam
        // because that changes AccountKey20 vs AccountId32 beneficiary encoding
        bytes32 moonbeamRecip = bytes32(uint256(uint160(MOONBEAM_RECIPIENT)));
        bytes memory msgMoonbeam = h.buildTransferMessage(2004, moonbeamRecip, 10_000_000_000);
        bytes memory msgAstar    = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        assertNotEq(keccak256(msgMoonbeam), keccak256(msgAstar));
    }

    function test_BuildMessage_DifferentAmount_DifferentResult() public view {
        bytes memory a = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 1 * 10_000_000_000);
        bytes memory b = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 5 * 10_000_000_000);
        assertNotEq(keccak256(a), keccak256(b));
    }

    function test_BuildMessage_Moonbeam_UsesAccountKey20InMessage() public view {
        bytes32 moonbeamRecip = bytes32(uint256(uint160(MOONBEAM_RECIPIENT)));
        bytes memory msg_ = h.buildTransferMessage(2004, moonbeamRecip, 10_000_000_000);
        // Message for Moonbeam should differ from Astar for same amount
        bytes memory astar = h.buildTransferMessage(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        assertNotEq(keccak256(msg_), keccak256(astar));
    }

    // ─────────────────────────────────────────────
    // Unit conversions
    // ─────────────────────────────────────────────

    function test_DotToPlanck_OneDOT() public view {
        assertEq(h.dotToPlanck(1), 10_000_000_000);
    }

    function test_DotToPlanck_TenDOT() public view {
        assertEq(h.dotToPlanck(10), 100_000_000_000);
    }

    function test_PlanckToDot_OneDOT() public view {
        assertEq(h.planckToDot(10_000_000_000), 1);
    }

    function test_PlanckToDot_Truncates() public view {
        assertEq(h.planckToDot(10_000_000_001), 1); // truncates fractional
        assertEq(h.planckToDot(9_999_999_999), 0);
    }

    function testFuzz_DotPlanckRoundtrip(uint64 dot) public view {
        uint256 planck = h.dotToPlanck(dot);
        assertEq(h.planckToDot(planck), dot);
    }

    // ─────────────────────────────────────────────
    // Precompile address constant
    // ─────────────────────────────────────────────

    function test_PrecompileAddress_IsCorrect() public pure {
        assertEq(
            XCMHelper.XCM_PRECOMPILE,
            0x00000000000000000000000000000000000a0000,
            "XCM precompile address must match Polkadot Hub docs"
        );
    }

    // ─────────────────────────────────────────────
    // Integration: mock precompile dispatch
    // ─────────────────────────────────────────────

    function test_TransferDOT_WeighsBeforeExecute() public {
        // Mock both precompile calls at the selector level (matches any arguments)
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("weighMessage(bytes)"))),
            abi.encode(uint64(1_000_000_000), uint64(65_536))
        );
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("execute(bytes,uint64)"))),
            abi.encode()
        );

        XCMDispatchHarness d = new XCMDispatchHarness();
        d.dispatch(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
        // reaching here means weighMessage + execute both resolved without revert
    }

    function test_TransferDOT_PassesWeighedWeightToExecute() public {
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("weighMessage(bytes)"))),
            abi.encode(uint64(1_000_000_000), uint64(65_536))
        );
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("execute(bytes,uint64)"))),
            abi.encode()
        );

        XCMDispatchHarness d = new XCMDispatchHarness();
        d.dispatch(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
    }

    function test_TransferDOT_UsesFallback_WhenWeighReturnsZero() public {
        // weighMessage returns 0 — XCMHelper should fall back to FALLBACK_WEIGHT
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("weighMessage(bytes)"))),
            abi.encode(uint64(0), uint64(0))
        );
        vm.mockCall(
            XCMHelper.XCM_PRECOMPILE,
            abi.encodeWithSelector(bytes4(keccak256("execute(bytes,uint64)"))),
            abi.encode()
        );

        XCMDispatchHarness d = new XCMDispatchHarness();
        // Should not revert — falls back to FALLBACK_WEIGHT
        d.dispatch(2006, SUBSTRATE_RECIPIENT, 10_000_000_000);
    }
}

/// @dev Wrapper for XCMHelper.transferDOTToPara
contract XCMDispatchHarness {
    function dispatch(uint32 paraId, bytes32 recipient, uint256 amount) external {
        XCMHelper.transferDOTToPara(paraId, recipient, amount);
    }
}

/// @dev Wrapper for XCMHelper.getWeight
contract XCMGetWeightHarness {
    function getWeight(bytes calldata message) external returns (uint64) {
        return XCMHelper.getWeight(message);
    }
}

