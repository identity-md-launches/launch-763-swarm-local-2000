// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Strike} from "./Strike.sol";

/// @notice Free, one-per-wallet, nontransferable ERC-721 membership card with live metadata.
contract UnionCard is ERC721 {
    using Strings for uint256;

    address public constant IDENTITY_MD = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    Strike public immutable strike;
    mapping(address => bool) public minted;
    error Soulbound();
    error Ineligible();
    event Locked(uint256 tokenId);

    constructor(address strike_) ERC721("Swarm Local 2000 Union Card", "STRIKE-CARD") {
        require(strike_ != address(0), "zero token");
        strike = Strike(strike_);
    }

    function mint() external returns (uint256 id) {
        (uint256 amount,,,,,,) = strike.stakes(msg.sender);
        if (minted[msg.sender] || strike.balanceOf(msg.sender) + amount == 0) revert Ineligible();
        minted[msg.sender] = true;
        id = uint256(uint160(msg.sender));
        _safeMint(msg.sender, id);
        emit Locked(id);
    }

    function gold(address account) public view returns (bool) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", account);
        address target = IDENTITY_MD;
        bool ok;
        uint256 size;
        uint256 value;
        assembly ("memory-safe") {
            ok := staticcall(30000, target, add(data, 32), mload(data), 0, 32)
            size := returndatasize()
            value := mload(0)
        }
        return ok && size == 32 && value > 0;
    }

    function locked(uint256 id) external view returns (bool) {
        _requireOwned(id);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (_ownerOf(id) != address(0)) revert Soulbound();
        return super._update(to, id, auth);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        address account = _requireOwned(id);
        (uint256 amount,,,,,,) = strike.stakes(account);
        uint256 bonus = strike.rankBonus(account);
        string memory rank =
            bonus == 15_000 ? "Veteran" : bonus == 12_500 ? "Organizer" : bonus == 11_000 ? "Member" : "Rookie";
        string memory color = gold(account) ? "#ffd166" : "#bbc3cc";
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480"><rect width="480" height="480" rx="30" fill="#151820"/>',
            '<text x="28" y="46" fill="',
            color,
            '" font-size="24">SWARM LOCAL 2000</text>',
            '<path d="M118 145L55 96L94 220M330 145L400 96L365 220" fill="#74a766"/>',
            '<ellipse cx="230" cy="197" rx="123" ry="99" fill="#82b671"/>',
            '<path d="M138 163L197 179M262 179L321 163" stroke="#172319" stroke-width="15"/>',
            '<circle cx="181" cy="194" r="10"/><circle cx="278" cy="194" r="10"/>',
            '<path d="M189 241Q230 224 269 241" fill="none" stroke="#172319" stroke-width="8"/>',
            '<path d="M145 277L104 406H357L310 277L236 310Z" fill="#f87823"/>',
            '<path d="M170 302V401M295 302V401" stroke="#ffe58a" stroke-width="17"/>',
            '<rect x="56" y="305" width="62" height="64" rx="8" fill="#eee"/><path d="M117 320Q156 335 117 350" fill="none" stroke="#eee" stroke-width="9"/>',
            '<path d="M340 318V433" stroke="#a97c50" stroke-width="9"/><rect x="281" y="276" width="175" height="65" fill="',
            color,
            '"/>',
            '<text x="292" y="316" font-size="25">ON $STRIKE</text>',
            '<text x="24" y="454" fill="white" font-size="21">',
            rank,
            " | UNION CARD</text></svg>"
        );
        string memory json = string.concat(
            '{"name":"Swarm Local 2000 #',
            id.toString(),
            '","description":"Soulbound membership. Live rank and stake; stake is in STRIKE minor units.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Rank","value":"',
            rank,
            '"},{"trait_type":"Stake (wei)","value":"',
            amount.toString(),
            '"},{"trait_type":"Gold","value":"',
            gold(account) ? "Yes" : "No",
            '"},{"trait_type":"Active","value":"',
            strike.balanceOf(account) + amount > 0 ? "Yes" : "No",
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
