// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * SecretDarts
 *
 * Privacy-preserving darts mini-game on Zama FHEVM:
 *
 * - User encrypts dart hit coordinates (x, y) in the browser with the Relayer SDK.
 * - Contract computes squared distance to the center under FHE.
 * - Contract maps the encrypted distance to an encrypted ring code:
 *      0 = miss
 *      1 = outer ring
 *      2 = inner ring
 *      3 = bull
 * - User decrypts their own result locally via userDecrypt.
 *
 * The contract never sees clear coordinates or distances – only ciphertexts and
 * clear radius thresholds configured by the owner.
 */

import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SecretDarts is ZamaEthereumConfig {
  // ---------------------------------------------------------------------------
  // Ownership
  // ---------------------------------------------------------------------------

  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // ---------------------------------------------------------------------------
  // Simple nonReentrant guard (future-proof for payable flows)
  // ---------------------------------------------------------------------------

  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Board configuration (squared radii)
  //
  // Coordinates are assumed to be already centered in the frontend, i.e.
  // (0,0) is the board center and x,y are small enough that x^2 + y^2 fits
  // into uint16 without overflow. The owner configures thresholds in terms of
  // squared distance:
  //
  //   dist2 <= bullRadius2   -> bull (3)
  //   dist2 <= innerRadius2  -> inner ring (2)
  //   dist2 <= outerRadius2  -> outer ring (1)
  //   else                   -> miss (0)
  // ---------------------------------------------------------------------------

  uint16 public bullRadius2;   // smallest radius (bull)
  uint16 public innerRadius2;  // middle ring
  uint16 public outerRadius2;  // biggest scoring ring
  bool   public boardConfigured;

  event BoardConfigured(
    uint16 bullRadius2,
    uint16 innerRadius2,
    uint16 outerRadius2
  );

  /**
   * Configure dartboard distance thresholds.
   *
   * @param _bullRadius2   squared radius for bull (center)
   * @param _innerRadius2  squared radius for inner ring
   * @param _outerRadius2  squared radius for outer ring
   *
   * Invariants expected (but not strictly enforced):
   *   0 < bullRadius2 < innerRadius2 < outerRadius2
   */
  function setBoardConfig(
    uint16 _bullRadius2,
    uint16 _innerRadius2,
    uint16 _outerRadius2
  ) external onlyOwner {
    require(_bullRadius2 > 0, "bullRadius2 must be > 0");
    require(
      _bullRadius2 < _innerRadius2 &&
      _innerRadius2 < _outerRadius2,
      "invalid radius ordering"
    );

    bullRadius2   = _bullRadius2;
    innerRadius2  = _innerRadius2;
    outerRadius2  = _outerRadius2;
    boardConfigured = true;

    emit BoardConfigured(_bullRadius2, _innerRadius2, _outerRadius2);
  }

  // ---------------------------------------------------------------------------
  // Player shots (encrypted state)
  // ---------------------------------------------------------------------------

  struct ShotOutcome {
    euint16 eX;         // encrypted x coordinate
    euint16 eY;         // encrypted y coordinate
    euint16 eDist2;     // encrypted squared distance to center
    euint16 eRingCode;  // encrypted ring code: 0=miss,1=outer,2=inner,3=bull
    bool    decided;    // true after at least one shot
  }

  // player => last shot outcome
  mapping(address => ShotOutcome) private shots;

  event ShotTaken(
    address indexed player,
    bytes32 xHandle,
    bytes32 yHandle,
    bytes32 dist2Handle,
    bytes32 ringCodeHandle
  );

  // ---------------------------------------------------------------------------
  // Main game function
  // ---------------------------------------------------------------------------

  /**
   * Throw a dart with encrypted coordinates.
   *
   * Frontend flow (high-level):
   * 1) User clicks on a graphical board to pick (x,y) in some integer grid.
   * 2) Frontend centers and normalizes coordinates around (0,0).
   * 3) Frontend encrypts both x and y using Relayer SDK:
   *      const buf = relayer.createEncryptedInput(contractAddr, userAddr);
   *      buf.add16(x);
   *      buf.add16(y);
   *      const { handles, inputProof } = await buf.encrypt();
   * 4) Call this function with:
   *      throwDart(handles[0], handles[1], inputProof)
   * 5) Use getMyLastShotHandles(...) + userDecrypt(...) to reveal ring code.
   */
  function throwDart(
    externalEuint16 encX,
    externalEuint16 encY,
    bytes calldata proof
  ) external nonReentrant {
    require(boardConfigured, "Board not configured");
    require(proof.length != 0, "missing proof");

    ShotOutcome storage S = shots[msg.sender];

    // Ingest encrypted coordinates
    euint16 eX = FHE.fromExternal(encX, proof);
    euint16 eY = FHE.fromExternal(encY, proof);

    // Allow contract and player to keep using these ciphertexts
    FHE.allowThis(eX);
    FHE.allowThis(eY);
    FHE.allow(eX, msg.sender);
    FHE.allow(eY, msg.sender);

    // Compute squared distance to center: dist2 = x^2 + y^2 (all under FHE)
    euint16 eXSq = FHE.mul(eX, eX);
    euint16 eYSq = FHE.mul(eY, eY);
    euint16 eDist2 = FHE.add(eXSq, eYSq);

    // Determine encrypted ring code based on squared radius thresholds.
    //
    // We encode:
    //   0 = miss
    //   1 = outer ring
    //   2 = inner ring
    //   3 = bull
    //
    // Using ascending selects so that closer rings overwrite outer ones.
    euint16 eZero = FHE.asEuint16(0);
    euint16 eRing = eZero;

    // dist2 <= outerRadius2 ? 1 : 0
    eRing = FHE.select(
      FHE.le(eDist2, FHE.asEuint16(outerRadius2)),
      FHE.asEuint16(1),
      eRing
    );

    // dist2 <= innerRadius2 ? 2 : previous
    eRing = FHE.select(
      FHE.le(eDist2, FHE.asEuint16(innerRadius2)),
      FHE.asEuint16(2),
      eRing
    );

    // dist2 <= bullRadius2 ? 3 : previous
    eRing = FHE.select(
      FHE.le(eDist2, FHE.asEuint16(bullRadius2)),
      FHE.asEuint16(3),
      eRing
    );

    // Persist encrypted outcome
    S.eX        = eX;
    S.eY        = eY;
    S.eDist2    = eDist2;
    S.eRingCode = eRing;
    S.decided   = true;

    // Ensure contract retains long-term rights on stored ciphertexts
    FHE.allowThis(S.eX);
    FHE.allowThis(S.eY);
    FHE.allowThis(S.eDist2);
    FHE.allowThis(S.eRingCode);

    // Allow player to decrypt everything via userDecrypt
    FHE.allow(S.eX, msg.sender);
    FHE.allow(S.eY, msg.sender);
    FHE.allow(S.eDist2, msg.sender);
    FHE.allow(S.eRingCode, msg.sender);

    emit ShotTaken(
      msg.sender,
      FHE.toBytes32(S.eX),
      FHE.toBytes32(S.eY),
      FHE.toBytes32(S.eDist2),
      FHE.toBytes32(S.eRingCode)
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only, no FHE ops)
  // ---------------------------------------------------------------------------

  /**
   * Returns encrypted handles for the caller's last shot:
   * - xHandle:       encrypted x coordinate
   * - yHandle:       encrypted y coordinate
   * - dist2Handle:   encrypted squared distance to center
   * - ringCodeHandle encrypted ring classification: 0..3
   * - decided:       whether a shot has been recorded
   *
   * Frontend uses these with userDecrypt(...) to reveal the result locally.
   */
  function getMyLastShotHandles()
    external
    view
    returns (
      bytes32 xHandle,
      bytes32 yHandle,
      bytes32 dist2Handle,
      bytes32 ringCodeHandle,
      bool decided
    )
  {
    ShotOutcome storage S = shots[msg.sender];
    return (
      FHE.toBytes32(S.eX),
      FHE.toBytes32(S.eY),
      FHE.toBytes32(S.eDist2),
      FHE.toBytes32(S.eRingCode),
      S.decided
    );
  }

  /**
   * Owner-only: expose another player's encrypted ring code handle.
   * This is still only a ciphertext; owner cannot see the clear value
   * unless they are also granted decryption rights in a custom flow.
   */
  function getPlayerRingHandle(address player)
    external
    view
    onlyOwner
    returns (bytes32 ringCodeHandle, bool decided)
  {
    ShotOutcome storage S = shots[player];
    return (FHE.toBytes32(S.eRingCode), S.decided);
  }
}
