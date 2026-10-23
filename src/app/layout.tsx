import type { Metadata } from 'next';
import './globals.css';
export const metadata:Metadata={title:'Campus Event Pulse | Find your next moment',description:'Discover what is happening around campus and make every moment count.'};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="en"><body>{children}</body></html>}
