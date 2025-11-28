# Secret Darts · Zama FHEVM

**Secret Darts** is a privacy-preserving on-chain dart game built on **Zama FHEVM**.

Players never reveal their exact hit coordinates in plaintext:

1. You click on a dartboard in the frontend.
2. Your coordinates `(x, y)` are mapped to a small integer grid and **encrypted in the browser** via the Relayer SDK.
3. The smart contract computes the squared distance to the center and the hit zone **entirely under FHE**.
4. The contract stores **only ciphertexts** and an encrypted ring code.
5. You privately decrypt your own result via `userDecrypt` and see whether you hit **Bull / Inner / Outer / Miss**.

The smart contract never sees your clear coordinates or clear distance – only encrypted values and ring codes.

---

## Core Idea

In a classic dart game, everyone sees where the dart landed. Here, the target hit is **fully opaque on-chain**:

* The contract holds encrypted `(x, y)` coordinates.
* It computes the squared distance `d² = x² + y²` under FHE.
* Using encrypted thresholds for **bull**, **inner ring**, and **outer ring**, it classifies the result and stores an **encrypted ring code**:

  * `0` → Miss
  * `1` → Outer ring
  * `2` → Inner ring
  * `3` → Bull
* Only the **player** can decrypt their own coordinates / distances / ring code via `userDecrypt`.

This makes **Secret Darts** a small but complete example of:

* FHE-based distance computation (squares, sums, comparisons)
* Encrypted classification into discrete categories
* Private result viewing through Zama’s Relayer SDK

---

## How It Works

### On-chain logic (Solidity + FHEVM)

The core contract (deployed on Sepolia FHEVM) keeps three public parameters and several encrypted values per player.

#### Board configuration

The admin (contract owner) configures the dartboard in terms of **squared radii**:

* `bullRadius2` – max squared distance to count as **Bull**
* `innerRadius2` – max squared distance to count as **Inner ring**
* `outerRadius2` – max squared distance to count as **Outer ring**
* `boardConfigured` – flag that the board is ready to use

These values are **plain uint16s** (they represent thresholds, not private user data). They can be updated via:

```solidity
setBoardConfig(uint16 _bullRadius2, uint16 _innerRadius2, uint16 _outerRadius2)
```

Constraints enforced on-chain:

* All radii are non-zero and increasing: `bull < inner < outer`
* The board must be configured before any throws are accepted

#### Player throws

When a player clicks on the board in the frontend:

1. The frontend maps pixel coordinates to a small **signed integer grid** (e.g. `[-180, 180]`).
2. Each coordinate is encoded into `uint16` (so we can store it in `euint16`) by mapping negative values into the `0..65535` range.
3. Using Zama’s Relayer SDK, the frontend creates two encrypted inputs:

   * `encX: externalEuint16`
   * `encY: externalEuint16`
4. It sends those handles plus a proof into the contract:

```solidity
function throwDart(
    externalEuint16 encX,
    externalEuint16 encY,
    bytes calldata proof
) external
```

Inside the contract:

* `FHE.fromExternal` ingests the encrypted coordinates.
* The contract grants itself and the caller access with `FHE.allowThis` / `FHE.allow`.
* It computes the squared distance under FHE:

  * `dx^2`, `dy^2`, and `dist2 = dx^2 + dy^2` using encrypted arithmetic.
* It compares `dist2` with the thresholds `bullRadius2`, `innerRadius2`, and `outerRadius2` using `FHE.le` / `FHE.gt` and `FHE.select`.
* It derives an encrypted ring code `eRing` in `{0, 1, 2, 3}`.

Finally, the contract stores per-player state:

* `eX`, `eY` – encrypted coordinates
* `eDist2` – encrypted squared distance
* `eRing` – encrypted hit category
* `hasShot` – boolean flag indicating there is a last shot

All values are stored as FHE ciphertexts and remain opaque on-chain.

#### Read access

The contract exposes handles only:

```solidity
function getMyLastShotHandles()
    external
    view
    returns (
      bytes32 xHandle,
      bytes32 yHandle,
      bytes32 dist2Handle,
      bytes32 ringHandle,
      bool    hasShot
    );

function getPlayerRingHandle(address player)
    external
    view
    returns (bytes32 ringHandle, bool hasShot);
```

* `getMyLastShotHandles` – player-only view, returns the handles for (x, y, dist², ring) for the caller.
* `getPlayerRingHandle` – public view; returns only the **encrypted** ring handle for any player.

Nobody can see the clear result unless they have decryption rights and call `userDecrypt` off-chain.

---

## Frontend UX & Data Flow

The DApp is a single-page HTML/JS UI with a custom layout, built with:

* **Ethers v6** – wallet connection and contract calls
* **Zama Relayer SDK** (`relayer-sdk-js`) – client-side encryption & decryption
* No frameworks, just vanilla HTML/CSS/JS (for easy embedding in any project)

### 1. Connect wallet

Top-right in the header:

* **Connect wallet** button (MetaMask / EIP-1193 provider)
* Shows current network chain ID and your address once connected
* Automatically attempts to switch/add **Sepolia FHEVM** if needed

Once connected, the app also initializes the Relayer instance:

```js
const relayer = await createInstance({
  ...SepoliaConfig,
  relayerUrl: RELAYER_URL,
  gatewayUrl: GATEWAY_URL,
  network: window.ethereum,
  debug: true,
});
```

### 2. Click the dartboard (choose coordinates)

On the right side:

* A circular **dartboard** visual with:

  * Crosshair axes
  * Stylized inner and outer rings
  * A glowing marker for your last click
* When you click:

  * The app converts pixel coords to an `(x, y)` integer pair.
  * The pair is **only stored locally** in JS state.
  * The UI shows

    ```text
    Coordinates: (x, y)
    ```

**No plaintext coordinates are sent on-chain.** Only the encoded and encrypted versions are used.

### 3. "Throw encrypted dart"

The **Throw encrypted dart** button:

* Reads the selected `(x, y)`.
* Encodes them into uint16 to fit `euint16`.
* Creates encrypted input via Relayer SDK:

```js
const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, userAddress);
buf.add16(encodedX);
buf.add16(encodedY);
const { handles, inputProof } = await buf.encrypt();
```

* Sends them into the contract:

```js
await contract.throwDart(handles[0], handles[1], inputProof);
```

After confirmation, the contract has computed and stored the encrypted result. The UI resets the visible result until you decrypt it again.

### 4. Decrypt your last shot

In the left column, under **Decrypt your ring**:

* Click **Decrypt last shot**.
* The app calls `getMyLastShotHandles()` to obtain the latest handles for:

  * x, y
  * dist²
  * ring
* It then calls `userDecrypt` via the Relayer SDK with a short-lived keypair and EIP-712 signature:

```js
const kp = await generateKeypair();
const eip = relayer.createEIP712(kp.publicKey, [CONTRACT_ADDRESS], startTs, daysValid);
const sig = await signer.signTypedData(
  eip.domain,
  { UserDecryptRequestVerification: eip.types.UserDecryptRequestVerification },
  eip.message
);

const out = await relayer.userDecrypt(
  pairs,
  kp.privateKey,
  kp.publicKey,
  sig.replace(/^0x/, ""),
  [CONTRACT_ADDRESS],
  userAddr,
  startTs,
  daysValid
);
```

* Frontend uses a helper `buildValuePicker` + `normalizeDecryptedValue` to safely map outputs (which can be `bigint | number | boolean | string`) into `BigInt`.
* It then:

  * Shows ring category as **Miss / Outer ring / Inner ring / Bull**.
  * Displays `d²` and an approximate distance.
  * (Optionally) decodes the encrypted x, y back into signed coordinates for your local view.

All decryption happens **in-browser** – nothing is sent back to the contract.

### HTTPS note

The UI displays a small pill label about HTTPS / secure context:

* On secure origin (HTTPS / localhost):

  * `decrypt: HTTPS ✓`
  * Full `userDecrypt` flow is expected to work.
* On non-secure origins:

  * `decrypt: open via HTTPS`
  * Browser security policies may restrict Workers/WASM, so some Relayer operations may not work.

---

## Project Structure

A typical repository layout:

```text
contracts/
  SecretDarts.sol         # FHEVM smart contract implementing encrypted darts

deploy/
  deploy.ts              # Hardhat deploy script pointing to SecretDarts

frontend/
  secret-darts.html      # Standalone HTML + JS UI (no bundler)

hardhat.config.ts        # Hardhat configuration for FHEVM dev/deploy
package.json             # Dependencies (hardhat, ethers, hardhat-deploy, etc.)
README.md                # This file
```

You can also keep the frontend at the repo root if preferred; `secret-darts.html` is self-contained and can be served by any static host.

---

## Contract API Reference (short)

### Board config

```solidity
function setBoardConfig(
  uint16 _bullRadius2,
  uint16 _innerRadius2,
  uint16 _outerRadius2
) external onlyOwner;

function boardConfigured() external view returns (bool);
function bullRadius2() external view returns (uint16);
function innerRadius2() external view returns (uint16);
function outerRadius2() external view returns (uint16);
```

### Player flow

```solidity
function throwDart(
  externalEuint16 encX,
  externalEuint16 encY,
  bytes calldata proof
) external;

function getMyLastShotHandles()
  external
  view
  returns (
    bytes32 xHandle,
    bytes32 yHandle,
    bytes32 dist2Handle,
    bytes32 ringHandle,
    bool    hasShot
  );

function getPlayerRingHandle(address player)
  external
  view
  returns (bytes32 ringHandle, bool hasShot);
```

---

## Running Locally

1. **Install dependencies**

```bash
pnpm install
# or
npm install
```

2. **Compile & deploy** (example for Sepolia)

```bash
npx hardhat compile
npx hardhat deploy --network sepolia
```

3. **Serve frontend**

Serve `secret-darts.html` over HTTPS or localhost (for example with `vite preview`, `http-server`, etc.).

4. **Play**

* Connect your wallet on Sepolia.
* If you are the owner, configure `bullRadius2`, `innerRadius2`, `outerRadius2`.
* Click on the board to choose a hit location.
* Press **Throw encrypted dart**.
* After the transaction confirms, use **Decrypt last shot** to see how you scored.

---

## Why FHE Here?

Secret Darts is intentionally simple yet expressive:

* Shows how to do **basic arithmetic (squares, sums)** under FHE.
* Demonstrates **threshold-based classification** without ever revealing raw inputs.
* Provides a light, visual game that feels familiar while being cryptographically novel.

The same pattern can be extended to:

* Private distance-based geofencing
* Proximity games / treasure hunts
* Medical or sensor data where only risk categories are revealed (not raw values)

All while keeping the sensitive numbers encrypted end-to-end.

---

## Notes & Limitations

* Randomness is not used in this game; it’s purely deterministic based on your chosen point.
* The contract does not publish any **publicly decryptable** values (no `makePubliclyDecryptable`) – all decryption is user-side via `userDecrypt`.
* Grid encoding/decoding for `(x, y)` is an implementation detail of the frontend; it can be tuned without touching the contract.

---

## License

MIT (or your preferred OSS license).

Feel free to fork, tweak the visuals, or integrate Secret Darts into a larger FHE game hub.
