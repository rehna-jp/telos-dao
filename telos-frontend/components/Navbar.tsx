'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { ConnectButton } from '@rainbow-me/rainbowkit'

export default function Navbar() {
  const pathname = usePathname()

  return (
    <nav className="navbar">
      <Link href="/" className="navbar-logo">
         <span>Telos</span> DAO
      </Link>

      <div className="navbar-nav">
        <Link href="/" className={`nav-link ${pathname === '/' ? 'active' : ''}`}>
          Proposals
        </Link>
        <Link href="/create" className={`nav-link ${pathname === '/create' ? 'active' : ''}`}>
          Create
        </Link>
        <Link href="/treasury" className={`nav-link ${pathname === '/treasury' ? 'active' : ''}`}>
          Treasury
        </Link>
      </div>

      <div className="navbar-right">
        <ConnectButton
          showBalance={false}
          chainStatus="icon"
          accountStatus="address"
        />
      </div>
    </nav>
  )
}
